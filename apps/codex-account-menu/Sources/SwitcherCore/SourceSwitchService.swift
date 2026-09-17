import Foundation
import Darwin

// Darwin also imports the POSIX `struct flock`; use an unambiguous binding for
// the BSD flock(2) function, whose locks distinguish separate open descriptors.
@_silgen_name("flock")
private func sourceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct MenuSelection: Codable, Equatable, Sendable {
    public let provider: String
    /// Selected official identity; explicit pure API selections never carry one.
    public let accountID: UUID?
    public let officialIdentityDisabled: Bool

    public init(provider: String, accountID: UUID? = nil, officialIdentityDisabled: Bool = false) {
        self.provider = provider
        self.officialIdentityDisabled = officialIdentityDisabled
        self.accountID = officialIdentityDisabled ? nil : accountID
    }

    private enum CodingKeys: String, CodingKey { case provider, accountID, officialIdentityDisabled }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try values.decode(String.self, forKey: .provider),
            accountID: try values.decodeIfPresent(UUID.self, forKey: .accountID),
            officialIdentityDisabled: try values.decodeIfPresent(Bool.self, forKey: .officialIdentityDisabled) ?? false)
    }

    init(route: ProviderRouteState, accountID: UUID?) {
        self.init(provider: route.logicalProvider, accountID: accountID,
            officialIdentityDisabled: route.isManaged && route.physicalProvider == "copilot")
    }
}

public struct SourceSwitchPreview: Sendable {
    public let sessionCount: Int
    public let backupBytesUpperBound: Int64
    public let stableRouting: Bool
}

public enum SourceTarget: Sendable {
    case chatGPT(UUID)
    /// Change the route while retaining the current local identity, even if expired.
    case copilot
    /// Select both the API route and a verified ChatGPT identity atomically.
    case copilotWithIdentity(UUID)
    /// Restore an explicitly disconnected API route without borrowing any identity.
    case copilotWithoutOfficialIdentity

    public static func restoring(_ selection: MenuSelection) throws -> SourceTarget {
        if selection.provider == "copilot", selection.officialIdentityDisabled {
            return .copilotWithoutOfficialIdentity
        }
        guard let accountID = selection.accountID else {
            throw SourceFileError.invalidConfiguration("the saved selection has no complete identity; choose an account explicitly before restoring")
        }
        switch selection.provider {
        case "openai": return .chatGPT(accountID)
        case "copilot": return .copilotWithIdentity(accountID)
        default: throw SourceFileError.invalidConfiguration("the saved provider is not supported")
        }
    }
}

public enum SourceSwitchStage: String, Sendable {
    case prepare, closeDesktop, verifyQuiescence, captureState, saveCurrentCredential, activateCredential
    case setProvider, verifyIdentity, setRelay, commitRegistry, reopenDesktop, completeRecoveryRecord
}

public struct SourceSwitchFailure: LocalizedError, Sendable {
    public let stage: SourceSwitchStage
    public let cause: String
    public let recoveryErrors: [String]
    /// Private OAuth files that changed during a failed verification/handoff.
    /// Their presence does not mean the credential passed identity verification.
    public let preservedCredentialFiles: [URL]
    /// Set before an operation that may persist source changes, rotate OAuth,
    /// or start/change the relay; a thrown error does not prove it had no effect.
    public let sourceMutationAttempted: Bool
    public let previousSelectionRestored: Bool
    public let desktopReopened: Bool

    public var errorDescription: String? {
        let recovery = !sourceMutationAttempted ? "No source changes were made by the switcher." :
            previousSelectionRestored ? "Previous identity and provider were restored." : "Previous state could not be fully restored; inspect the files before reopening Codex."
        let details = recoveryErrors.isEmpty ? "" : " Recovery: " + recoveryErrors.joined(separator: "; ")
        let preserved = preservedCredentialFiles.isEmpty ? "" : " Changed OAuth credentials were preserved for recovery (verification is required before use): " + preservedCredentialFiles.map(\.path).joined(separator: ", ")
        return "Source switch failed at \(stage.rawValue): \(cause) \(recovery)\(details)\(preserved)"
    }
}

public actor SourceSwitchService {
    private let store: AccountStore
    private let codex: any AccountClient
    private let desktop: any DesktopControlling
    private let provider: ProviderConfiguration
    private let relay: (any APIRelayControlling)?
    private let activityGuard: CodexActivityGuard?
    private let recoveryGuard: SwitchRecoveryGuard
    private var switching = false

    public init(store: AccountStore, codex: any AccountClient, desktop: any DesktopControlling, provider: ProviderConfiguration,
                relay: (any APIRelayControlling)? = nil, activityGuard: CodexActivityGuard? = nil,
                recoveryGuard: SwitchRecoveryGuard? = nil) {
        self.store = store; self.codex = codex; self.desktop = desktop; self.provider = provider
        self.relay = relay; self.activityGuard = activityGuard
        self.recoveryGuard = recoveryGuard ?? SwitchRecoveryGuard(baseURL: store.baseURL, home: store.activeHomeURL)
    }

    /// Reports local selection only; account/read is not a model request or a route test.
    public func currentSelection() async throws -> MenuSelection {
        guard !switching else { throw SourceFileError.busy }
        let lock = try SourceSwitchLock(home: await store.activeCodexHome())
        defer { lock.release() }
        let configuration = try await provider.snapshot()
        let route = try await provider.readRoute()
        let accounts = try await store.sourceSnapshot(targetID: nil)
        try configuration.file.requireUnchanged()
        try accounts.registryFile.requireUnchanged()
        return MenuSelection(route: route, accountID: accounts.registry.activeAccountID)
    }

    public func restoreSelection(_ selection: MenuSelection) async throws -> MenuSelection {
        try await switchSource(to: SourceTarget.restoring(selection))
    }

    public func preview(to target: SourceTarget) async throws -> SourceSwitchPreview {
        guard !switching else { throw SourceFileError.busy }
        let home = await store.activeCodexHome()
        let lock = try SourceSwitchLock(home: home)
        defer { lock.release() }
        guard relay != nil else {
            return SourceSwitchPreview(sessionCount: 0, backupBytesUpperBound: 0, stableRouting: false)
        }
        guard let activityGuard, activityGuard.home == home.standardizedFileURL else {
            throw SourceFileError.invalidConfiguration("stable routing requires the matching activity guard")
        }
        let logical: String, identity: UUID?
        switch target {
        case .chatGPT(let id): logical = "openai"; identity = id
        case .copilotWithIdentity(let id): logical = "copilot"; identity = id
        case .copilotWithoutOfficialIdentity: logical = "copilot"; identity = nil
        case .copilot:
            logical = "copilot"
            let current = try await store.sourceSnapshot(targetID: nil)
            identity = current.active.data == nil ? nil : current.registry.activeAccountID
        }
        if let identity { _ = try await store.profile(id: identity) }
        let config = try await provider.snapshot()
        _ = try await provider.previewRoute(logical, hasOfficialIdentity: identity != nil, expecting: config)
        try config.file.requireUnchanged()
        return SourceSwitchPreview(sessionCount: 0, backupBytesUpperBound: 0, stableRouting: true)
    }

    public func switchSource(to target: SourceTarget) async throws -> MenuSelection {
        try await performSwitch(to: target)
    }

    /// Resolve the previous combination under the same lock as the switch, so a
    /// running GUI cannot restore a stale record after a CLI source change.
    public func restorePreviousSelection() async throws -> MenuSelection {
        try await performSwitch(to: nil)
    }

    private func performSwitch(to requestedTarget: SourceTarget?) async throws -> MenuSelection {
        guard !switching else { throw SourceFileError.busy }
        switching = true
        defer { switching = false }
        let home = await store.activeCodexHome()
        guard home.standardizedFileURL == provider.codexHome.standardizedFileURL else {
            throw SourceFileError.invalidConfiguration("account storage and provider configuration use different CODEX_HOME directories")
        }
        let lock = try SourceSwitchLock(home: home)
        defer { lock.release() }
        var stage = SourceSwitchStage.prepare
        var closed = false
        var reopenAttempted = false
        var sourceMutationAttempted = false
        var original: SourceStoreSnapshot?
        var originalProvider: ProviderSnapshot?
        var ownedAuth: SourceFileSnapshot?
        var ownedConfig: SourceFileSnapshot?
        var ownedRegistry: SourceFileSnapshot?
        var originalPrevious: SourceFileSnapshot?
        var ownedPrevious: SourceFileSnapshot?
        var rollbackAuth: Data?
        var pendingRecoveries: [CredentialRecovery] = []
        var previousRelay: APIRelayStatus?
        var previousRouteRequiredRelay = false
        var expectedRelayInstanceID: String?
        var relayChanged = false
        var recoveryCheckpoint: SwitchRecoveryCheckpoint?
        var recoveryTransaction: SwitchRecoveryTransaction?

        do {
            // Reject a shared store bound to another home before any Desktop
            // lifecycle or relay operation, including pure API/back selections.
            _ = try await store.loadRegistry()
            guard AccountStoreBinding.canonical(recoveryGuard.baseURL) == AccountStoreBinding.canonical(store.baseURL) else {
                throw SourceSwitchRecoveryError.invalidRecord
            }
            recoveryCheckpoint = try recoveryGuard.prepare(lock: lock)
            let target: SourceTarget
            if let requestedTarget { target = requestedTarget }
            else {
                let saved = try SourceFileSnapshot.read(store.baseURL.appendingPathComponent("previous-source.json"))
                guard let bytes = saved.data else {
                    throw SourceFileError.invalidConfiguration("there is no saved previous selection")
                }
                target = try SourceTarget.restoring(JSONDecoder().decode(MenuSelection.self, from: bytes))
                try saved.requireUnchanged()
            }
            var targetID: UUID?
            let targetProvider: String
            switch target {
            case .chatGPT(let id):
                targetID = id; targetProvider = "openai"
            case .copilotWithIdentity(let id):
                targetID = id; targetProvider = "copilot"
            case .copilot, .copilotWithoutOfficialIdentity:
                targetID = nil; targetProvider = "copilot"
            }
            if case .copilotWithoutOfficialIdentity = target, relay == nil {
                throw SourceFileError.invalidConfiguration("restoring pure API requires the managed relay and activity guard")
            }
            if relay != nil, case .copilot = target {
                let current = try await store.sourceSnapshot(targetID: nil)
                // Retain only the currently loaded identity. A missing auth.json
                // never causes a historical saved account to be imported.
                if current.active.data != nil { targetID = current.registry.activeAccountID }
            }
            if let targetID { _ = try await store.profile(id: targetID) }
            if let relay {
                guard let activityGuard, activityGuard.home == home.standardizedFileURL else {
                    throw SourceFileError.invalidConfiguration("stable routing requires the matching activity guard")
                }
                let snapshot = try await provider.snapshot()
                _ = try await provider.previewRoute(targetProvider, hasOfficialIdentity: targetID != nil, expecting: snapshot)
                let route = try await provider.readRoute()
                try snapshot.file.requireUnchanged()
                previousRouteRequiredRelay = route.isManaged && route.apiEnabled
                previousRelay = try await relay.status()
                expectedRelayInstanceID = previousRelay?.instanceId
            } else if targetProvider == "copilot" {
                try await provider.validateCopilotPreservingIdentity()
            } else {
                _ = try await provider.readProvider()
            }
            stage = .closeDesktop
            try await desktop.closeDesktop()
            closed = true
            if relay != nil, !(try await desktop.isDesktopStopped()) { throw CodexActivityError.desktopRunning }

            stage = .verifyQuiescence
            try await requireQuiescent(lock: lock)
            if targetProvider == "copilot", let relay {
                // An authorized upgrade may replace this instance. Reject an
                // unrelated replacement that appeared before the upgrade call.
                if let current = try await relay.status(), current.instanceId != expectedRelayInstanceID {
                    throw APIRelayError.unexpectedService
                }
                try beginSourceMutation(checkpoint: recoveryCheckpoint, transaction: &recoveryTransaction, lock: lock)
                sourceMutationAttempted = true
                relayChanged = true
                // This can shut down an idle old relay before a new launch
                // fails; recovery must account for that even without a reply.
                let running = try await relay.ensureRunningForSourceSwitch()
                expectedRelayInstanceID = running.instanceId
            }

            stage = .captureState
            let snapshot = try await store.sourceSnapshot(targetID: targetID)
            if relay != nil, case .copilot = target {
                // A normal quit may finish an in-flight native logout. Only the
                // stopped snapshot decides which current identity is retained.
                targetID = snapshot.active.data == nil ? nil : snapshot.registry.activeAccountID
            }
            original = snapshot
            ownedAuth = snapshot.active; ownedRegistry = snapshot.registryFile
            rollbackAuth = snapshot.active.data
            let configuration = try await provider.snapshot()
            let previousRoute = try await provider.readRoute()
            originalProvider = configuration; ownedConfig = configuration.file
            originalPrevious = try SourceFileSnapshot.read(store.baseURL.appendingPathComponent("previous-source.json"))
            ownedPrevious = originalPrevious
            try snapshot.active.requireUnchanged()
            try snapshot.registryFile.requireUnchanged()
            try configuration.file.requireUnchanged()
            var profileFiles = snapshot.credentials

            if let relay {
                guard try await desktop.isDesktopStopped() else { throw CodexActivityError.desktopRunning }
                stage = .setRelay
                // An idle desktop can retain a pooled WebSocket. Normal app exit
                // closes it; permit a short drain before requiring an idle relay.
                var state = try await relay.status()
                for _ in 0..<40 where state?.isIdle == false {
                    try await Task.sleep(for: .milliseconds(50))
                    state = try await relay.status()
                }
                if let current = state {
                    guard current.isIdle else { throw APIRelayError.busy }
                    if current.instanceId != expectedRelayInstanceID { throw APIRelayError.unexpectedService }
                    // Mark before awaiting: a lost control reply may follow a
                    // successful state change and still requires rollback.
                    try beginSourceMutation(checkpoint: recoveryCheckpoint, transaction: &recoveryTransaction, lock: lock)
                    relayChanged = true
                    sourceMutationAttempted = true
                    _ = try await relay.setEnabled(targetProvider == "copilot")
                } else if targetProvider == "copilot" { throw APIRelayError.unavailable("转发进程在切换前退出") }
            }

            stage = .saveCurrentCredential
            if let id = snapshot.registry.activeAccountID {
                guard let profile = snapshot.registry.accounts.first(where: { $0.id == id }),
                      let saved = profileFiles[id] else {
                    throw AccountStoreError.activeProfileMissing
                }
                if let activeBytes = snapshot.active.data {
                    // A revoked subscription or failed quota endpoint must not trap
                    // the user in the current account. Preserve its latest local
                    // OAuth only; upstream verification belongs to the destination.
                    try validateOAuthCredential(activeBytes, matching: profile)
                    try snapshot.registryFile.requireUnchanged()
                    try configuration.file.requireUnchanged()
                    try snapshot.active.requireUnchanged()
                    try beginSourceMutation(checkpoint: recoveryCheckpoint, transaction: &recoveryTransaction, lock: lock)
                    sourceMutationAttempted = true
                    profileFiles[id] = try saved.replace(with: activeBytes)
                }
                // Native logout may delete auth.json while leaving the last profile
                // registered. Preserve this missing-file state as the rollback point.
            } else if snapshot.active.data != nil {
                throw AccountStoreError.activeProfileMissing
            }

            let selectedProvider: String
            let selectedID: UUID?
            if let id = targetID {
                guard let profile = snapshot.registry.accounts.first(where: { $0.id == id }),
                      let saved = profileFiles[id], let targetBytes = saved.data else {
                    throw AccountStoreError.targetCredentialMissing
                }
                stage = .activateCredential
                try validateOAuthCredential(targetBytes, matching: profile)
                try saved.requireUnchanged()
                try ownedRegistry!.requireUnchanged()
                try ownedConfig!.requireUnchanged()
                try beginSourceMutation(checkpoint: recoveryCheckpoint, transaction: &recoveryTransaction, lock: lock)
                sourceMutationAttempted = true
                ownedAuth = try ownedAuth!.replace(with: targetBytes)

                stage = .setProvider
                var applied = try await applyProvider(targetProvider, hasOfficialIdentity: true, expecting: configuration)
                ownedConfig = applied.file
                stage = .verifyIdentity
                let probe: CredentialProbe?
                do {
                    probe = try await verifiedCredential(targetBytes, profile: profile,
                        effectiveConfiguration: targetProvider == "copilot" || relay != nil ? applied.file.data : nil)
                } catch {
                    // The simple API choice must remain usable when the current
                    // subscription is revoked. Never activate an unverified
                    // identity, or lose an OAuth rotation while falling back.
                    guard relay != nil, case .copilot = target,
                          !(error is CredentialVerificationFailure), !(error is SourceFileError) else { throw error }
                    guard try await desktop.isDesktopStopped() else { throw CodexActivityError.desktopRunning }
                    applied = try await applyProvider("copilot", hasOfficialIdentity: false, expecting: applied)
                    ownedConfig = applied.file
                    targetID = nil
                    probe = nil
                }
                if let probe {
                    if let recovery = probe.recovery { pendingRecoveries.append(recovery) }
                    let verified = probe.bytes
                    if relay != nil, !(try await desktop.isDesktopStopped()) { throw CodexActivityError.desktopRunning }
                    try ownedAuth!.requireUnchanged()
                    try ownedConfig!.requireUnchanged()
                    try ownedRegistry!.requireUnchanged()
                    _ = try saved.replace(with: verified)
                    ownedAuth = try ownedAuth!.replace(with: verified)
                    if id == snapshot.registry.activeAccountID && snapshot.active.data != nil { rollbackAuth = verified }
                    acknowledge(probe.recovery, pending: &pendingRecoveries)
                    selectedID = id
                } else { selectedID = nil }
                selectedProvider = targetProvider

            } else {
                stage = .setProvider
                try ownedAuth!.requireUnchanged()
                try ownedRegistry!.requireUnchanged()
                try beginSourceMutation(checkpoint: recoveryCheckpoint, transaction: &recoveryTransaction, lock: lock)
                sourceMutationAttempted = true
                let applied = try await applyProvider("copilot", hasOfficialIdentity: false, expecting: configuration)
                ownedConfig = applied.file
                selectedProvider = "copilot"; selectedID = snapshot.registry.activeAccountID
            }

            if relay != nil, targetID == nil, let bytes = ownedConfig?.data {
                stage = .verifyIdentity
                try await verifyPureAPIConfiguration(bytes)
            }

            stage = .commitRegistry
            try await requireQuiescent(lock: lock)
            try ownedAuth!.requireUnchanged()
            try ownedConfig!.requireUnchanged()
            try ownedRegistry!.requireUnchanged()
            if let id = targetID {
                ownedRegistry = try await store.commitSourceAccount(id, expecting: ownedRegistry!)
            }
            let previous = MenuSelection(route: previousRoute, accountID: snapshot.registry.activeAccountID)
            ownedPrevious = try ownedPrevious!.replace(with: JSONEncoder().encode(previous))
            try ownedAuth!.requireUnchanged()
            try ownedConfig!.requireUnchanged()
            try ownedRegistry!.requireUnchanged()
            stage = .reopenDesktop
            reopenAttempted = true
            try await desktop.reopenDesktop()
            stage = .completeRecoveryRecord
            if let recoveryTransaction {
                try recoveryGuard.complete(recoveryTransaction, recoveredPreviousState: false, lock: lock)
            }
            return MenuSelection(provider: selectedProvider, accountID: selectedID,
                officialIdentityDisabled: relay != nil && selectedProvider == "copilot" && targetID == nil)
        } catch {
            let cause = error.localizedDescription
            if let failure = error as? CredentialVerificationFailure {
                pendingRecoveries.append(failure.recovery)
            }
            var recoveryErrors: [String] = []
            // A stopped desktop is not evidence that we changed source state.
            // Before the first mutating call, reopening needs no recovery writes
            // and must not be blocked by the writer that rejected the switch.
            var mayRestore = closed && sourceMutationAttempted
            if reopenAttempted {
                // A failed launch callback does not prove that no application was
                // started. Re-establish a stopped writer before restoring files.
                do { try await desktop.closeDesktop() }
                catch {
                    mayRestore = false
                    recoveryErrors.append("Could not close the partially reopened application: \(error.localizedDescription)")
                }
            }
            if mayRestore, relay != nil {
                do {
                    try await requireQuiescent(lock: lock)
                } catch {
                    mayRestore = false
                    recoveryErrors.append("Recovery writes were withheld because native writer quiescence could not be verified: \(error.localizedDescription)")
                }
            }
            if mayRestore {
                if let original, let ownedRegistry {
                    restore(ownedRegistry, to: original.registryFile.data, errors: &recoveryErrors)
                }
                if let originalPrevious, let ownedPrevious { restore(ownedPrevious, to: originalPrevious.data, errors: &recoveryErrors) }
                if let originalProvider, let ownedConfig {
                    restore(ownedConfig, to: originalProvider.file.data, privateFile: false, errors: &recoveryErrors)
                }
                if let ownedAuth { restore(ownedAuth, to: rollbackAuth, errors: &recoveryErrors) }
                if (relayChanged || previousRouteRequiredRelay), let relay {
                    do {
                        try await restoreRelay(relay, previous: previousRelay,
                            expectedInstanceID: expectedRelayInstanceID, requiredByPreviousRoute: previousRouteRequiredRelay)
                    }
                    catch { recoveryErrors.append(error.localizedDescription) }
                }
            }
            // Restoring the old bytes is insufficient if a private process may
            // already have rotated the original account's refresh token.
            let originalCredentialNeedsRecovery = original?.active.data != nil && pendingRecoveries.contains {
                $0.profileID == original?.registry.activeAccountID
            }
            var restored = !sourceMutationAttempted || !closed || (mayRestore && recoveryErrors.isEmpty && !originalCredentialNeedsRecovery)
            // A prior interrupted transaction's starting state was already
            // unconfirmed. Restoring this attempt's bytes cannot make it safe.
            if recoveryCheckpoint?.record != nil { restored = false }
            if restored, let recoveryTransaction {
                do { try recoveryGuard.complete(recoveryTransaction, recoveredPreviousState: true, lock: lock) }
                catch {
                    restored = false
                    recoveryErrors.append("The source switch protection record could not be completed: \(error.localizedDescription)")
                }
            }
            var reopened = false
            if closed && restored {
                do { try await desktop.reopenDesktop(); reopened = true }
                catch { recoveryErrors.append("Reopening the previous selection failed: \(error.localizedDescription)") }
            }
            throw SourceSwitchFailure(stage: stage, cause: cause, recoveryErrors: recoveryErrors,
                preservedCredentialFiles: pendingRecoveries.map(\.authURL),
                sourceMutationAttempted: sourceMutationAttempted,
                previousSelectionRestored: restored, desktopReopened: reopened)
        }
    }

    private func restoreRelay(_ relay: any APIRelayControlling, previous: APIRelayStatus?,
                              expectedInstanceID: String?, requiredByPreviousRoute: Bool) async throws {
        let enabled = previous?.enabled ?? requiredByPreviousRoute
        var allowedInstances = Set([previous?.instanceId, expectedInstanceID].compactMap { $0 })
        var current = try await relay.status()
        if current == nil && enabled {
            // Recovery uses the ordinary start path, never a second upgrade.
            // Native auth/config have already been restored under quiescence.
            let restarted = try await relay.ensureRunning()
            allowedInstances.insert(restarted.instanceId)
            current = restarted
        }
        guard let current else { return } // An absent disabled relay is safe.
        guard allowedInstances.contains(current.instanceId) else { throw APIRelayError.unexpectedService }
        guard current.isIdle else { throw APIRelayError.busy }
        if current.enabled != enabled {
            let applied = try await relay.setEnabled(enabled)
            guard applied.instanceId == current.instanceId, applied.enabled == enabled else {
                throw APIRelayError.unexpectedService
            }
        }
        guard let verified = try await relay.status(), verified.instanceId == current.instanceId,
              verified.enabled == enabled, verified.isIdle else {
            throw APIRelayError.unavailable("未能确认原来源的转发状态已经恢复")
        }
    }

    private func beginSourceMutation(checkpoint: SwitchRecoveryCheckpoint?,
                                     transaction: inout SwitchRecoveryTransaction?, lock: SourceSwitchLock) throws {
        try lock.requireHeld(for: recoveryGuard.home)
        if let transaction {
            try transaction.file.requireUnchanged()
            return
        }
        guard let checkpoint else { throw SourceSwitchRecoveryError.invalidRecord }
        transaction = try recoveryGuard.begin(checkpoint, lock: lock)
    }

    private func requireQuiescent(lock: SourceSwitchLock) async throws {
        guard relay != nil, let activityGuard else { return }
        try await activityGuard.requireQuiescent(lock: lock, desktopStopped: { [desktop] in
            try await desktop.isDesktopStopped()
        })
    }

    private func applyProvider(_ value: String, hasOfficialIdentity: Bool,
                               expecting snapshot: ProviderSnapshot) async throws -> ProviderSnapshot {
        if relay != nil {
            return try await provider.setRoute(value, hasOfficialIdentity: hasOfficialIdentity, expecting: snapshot)
        }
        return try await provider.setProvider(value, expecting: snapshot)
    }

    private func verifyPureAPIConfiguration(_ bytes: Data) async throws {
        let directory = store.baseURL.appendingPathComponent("route-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try SourceFileSnapshot.read(directory.appendingPathComponent("config.toml")).replace(with: bytes)
        let status = try await codex.readEffectiveAuthStatus(profileHome: directory)
        guard !status.requiresOpenaiAuth, status.identity == nil else {
            throw SourceFileError.invalidConfiguration("pure API configuration unexpectedly requires an official identity")
        }
    }

    private func verifiedCredential(_ bytes: Data, profile: AccountProfile, effectiveConfiguration: Data? = nil) async throws -> CredentialProbe {
        try validateOAuthCredential(bytes, matching: profile)
        // A failed quota/read call can still have successfully rotated OAuth.
        // Use private persistent storage, and clean up only after unchanged bytes
        // or an acknowledged save to the profile and active credential.
        let recoveryRoot = store.baseURL.appendingPathComponent("credential-recovery")
        if FileManager.default.fileExists(atPath: recoveryRoot.path) {
            let values = try recoveryRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SourceFileError.unsafe("credential-recovery")
            }
        } else {
            try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryRoot.path)
        let directory = recoveryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var removeDirectory = true
        defer { if removeDirectory { try? FileManager.default.removeItem(at: directory) } }
        let credential = directory.appendingPathComponent("auth.json")
        _ = try SourceFileSnapshot.read(credential).replace(with: bytes)
        let config = directory.appendingPathComponent("config.toml")
        _ = try SourceFileSnapshot.read(config).replace(with: Data("model_provider = \"openai\"\ncli_auth_credentials_store = \"file\"\n".utf8))
        do {
            let identity = try await codex.verifyIdentity(profileHome: directory)
            guard identity.matches(profile), identity.accountID == profile.accountID else {
                throw AccountStoreError.activeCredentialMismatch
            }
            if let effectiveConfiguration {
                // Keep both possible OAuth rotations in this same recovery bundle.
                // The second probe uses the exact applied config with no provider or
                // credential-store override, so it checks the intended combination.
                guard let refreshedBytes = try SourceFileSnapshot.read(credential).data else {
                    throw AccountStoreError.activeCredentialMissing
                }
                try validateOAuthCredential(refreshedBytes, matching: profile)
                _ = try SourceFileSnapshot.read(config).replace(with: effectiveConfiguration)
                let status = try await codex.readEffectiveAuthStatus(profileHome: directory)
                guard status.authMethod == "chatgpt", status.requiresOpenaiAuth,
                      let effectiveIdentity = status.identity,
                      effectiveIdentity.matches(profile), effectiveIdentity.accountID == profile.accountID else {
                    throw AccountStoreError.activeCredentialMismatch
                }
            }
            let refreshed = try SourceFileSnapshot.read(credential)
            guard let data = refreshed.data else { throw AccountStoreError.activeCredentialMissing }
            try validateOAuthCredential(data, matching: profile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
            let recovery = data == bytes ? nil : CredentialRecovery(profileID: profile.id, directory: directory)
            removeDirectory = recovery == nil
            return CredentialProbe(bytes: data, recovery: recovery)
        } catch {
            if let current = try? SourceFileSnapshot.read(credential), let changed = current.data, changed != bytes {
                // Keep even an inconsistent changed file quarantined for inspection;
                // it is never installed or associated with a saved account here.
                removeDirectory = false
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
                throw CredentialVerificationFailure(cause: error.localizedDescription,
                    recovery: CredentialRecovery(profileID: profile.id, directory: directory))
            }
            throw error
        }
    }

    private func acknowledge(_ recovery: CredentialRecovery?, pending: inout [CredentialRecovery]) {
        guard let recovery else { return }
        try? FileManager.default.removeItem(at: recovery.directory)
        pending.removeAll { $0.directory == recovery.directory }
    }

    private func restore(_ owned: SourceFileSnapshot, to bytes: Data?, privateFile: Bool = true, errors: inout [String]) {
        do {
            // An external writer may already have restored the desired bytes.
            if try SourceFileSnapshot.read(owned.url).data == bytes { return }
            _ = try owned.replace(with: bytes, privateFile: privateFile)
        } catch { errors.append(error.localizedDescription) }
    }
}

private struct CredentialRecovery: Sendable {
    let profileID: UUID
    let directory: URL
    var authURL: URL { directory.appendingPathComponent("auth.json") }
}

private struct CredentialProbe: Sendable {
    let bytes: Data
    let recovery: CredentialRecovery?
}

private struct CredentialVerificationFailure: LocalizedError, Sendable {
    let cause: String
    let recovery: CredentialRecovery
    var errorDescription: String? { cause }
}

/// Non-reentrant lock shared by menu/CLI operations that may refresh credentials.
/// Hold it until owned helper processes have exited; switchSource owns its own lock.
public final class SourceSwitchLock: @unchecked Sendable {
    private var descriptor: Int32
    private let lifecycleLock = NSLock()
    private let lockedHome: URL
    private let fileURL: URL

    public init(home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        lockedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let file = home.appendingPathComponent(".codex-account-menu.lock")
        fileURL = file
        descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard sourceFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor); descriptor = -1
            throw SourceFileError.busy
        }
    }
    public func requireHeld(for home: URL) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard descriptor >= 0,
              home.resolvingSymlinksInPath().standardizedFileURL == lockedHome else {
            throw SourceFileError.busy
        }
        var held = stat(), current = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.lstat(fileURL.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw SourceFileError.unsafe("source switch lock")
        }
    }
    public func release() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if descriptor >= 0 { _ = sourceFlock(descriptor, LOCK_UN); _ = Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
