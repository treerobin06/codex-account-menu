import Foundation
import Testing
import SQLite3
@testable import SwitcherCore

// Real lsof probes share system inspection resources. Test concurrency inside
// an individual transaction explicitly, without launching every probe at once.
@Suite(.serialized)
struct SourceSwitchTests {
    @Test func explicitAPISwitchAcceptsItsUpgradedRelayInstance() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceUpgradingRelay()
        let originalInstance = try #require(try await relay.status()).instanceId
        let desktop = SourceDesktop()
        _ = try await f.stableService(relay: relay, desktop: desktop).switchSource(to: .copilotWithIdentity(f.b.id))
        let final = try #require(try await relay.status())
        #expect(final.instanceId != originalInstance && final.enabled)
        #expect(await relay.callCounts() == [1, 0])
        #expect(await desktop.counts() == [1, 1])
        #expect(try f.recoveryGuard.pendingRecord() == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func failedRelayUpgradeRestartsPreviousAPIBeforeReopenOrRetainsRecovery(restartFails: Bool, initiallyPresent: Bool) async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        try await f.configureManagedAPI()
        let beforeConfig = try Data(contentsOf: f.config)
        let relay = SourceUpgradingRelay(enabled: true, initiallyPresent: initiallyPresent,
            failUpgradeAfterShutdown: true, failRestart: restartFails)
        let desktop = SourceDesktop()
        let service = f.stableService(relay: relay, desktop: desktop)
        let failure = try #require(await switchFailure(service, target: .copilotWithIdentity(f.b.id)))
        #expect(failure.stage == .verifyQuiescence && failure.sourceMutationAttempted)
        #expect(failure.previousSelectionRestored == !restartFails)
        #expect(failure.desktopReopened == !restartFails)
        #expect(await relay.callCounts() == [1, 1])
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try Data(contentsOf: f.config) == beforeConfig)
        if restartFails {
            #expect(try await relay.status() == nil)
            #expect(!failure.recoveryErrors.isEmpty)
            #expect(try f.recoveryGuard.pendingRecord() != nil)
            #expect(await desktop.counts() == [1, 0])
        } else {
            #expect(try await relay.status()?.enabled == true)
            #expect(failure.recoveryErrors.isEmpty)
            #expect(try f.recoveryGuard.pendingRecord() == nil)
            #expect(await desktop.counts() == [1, 1])
        }
    }

    @Test(arguments: [false, true])
    func postUpgradeIdentityFailureRestoresOldEnabledStateOnTheNewInstance(previouslyAPI: Bool) async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        if previouslyAPI { try await f.configureManagedAPI() }
        let relay = SourceUpgradingRelay(enabled: previouslyAPI)
        let previousInstance = try #require(try await relay.status()).instanceId
        let failure = try #require(await switchFailure(f.stableService(relay: relay, client: SourceClient(mismatchOn: 1)),
            target: .copilotWithIdentity(f.b.id)))
        #expect(failure.stage == .verifyIdentity && failure.previousSelectionRestored && failure.desktopReopened)
        let restored = try #require(try await relay.status())
        #expect(restored.instanceId != previousInstance && restored.enabled == previouslyAPI)
        #expect(await relay.callCounts() == [1, 0])
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try f.recoveryGuard.pendingRecord() == nil)
    }

    @Test func unexpectedPostUpgradeReplacementCannotBeAcknowledgedByRollback() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceUpgradingRelay()
        let client = SourceClient(hook: { _, _ in
            await relay.replaceUnexpectedly()
            throw SourceTestError.injected
        })
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(f.stableService(relay: relay, client: client, desktop: desktop),
            target: .copilotWithIdentity(f.b.id)))
        #expect(!failure.previousSelectionRestored && !failure.desktopReopened)
        #expect(!failure.recoveryErrors.isEmpty)
        #expect(try f.recoveryGuard.pendingRecord() != nil)
        #expect(await desktop.counts() == [1, 0])
    }

    @Test func nativeSwitchDoesNotRequestRelayUpgrade() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceUpgradingRelay()
        _ = try await f.stableService(relay: relay).switchSource(to: .chatGPT(f.b.id))
        #expect(await relay.callCounts() == [0, 0])
    }

    @Test func recoveryRecordExistsBeforeRelayStartupAndClearsAfterSuccess() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let guarder = f.recoveryGuard
        let relay = SourceRelay(onStart: {
            let pending = try guarder.pendingRecord()
            #expect(pending != nil)
        })
        _ = try await f.stableService(relay: relay).switchSource(to: .copilotWithIdentity(f.b.id))
        #expect(try guarder.pendingRecord() == nil)
        try guarder.requireSafeAutomaticWork()
    }

    @Test func completeRollbackClearsOnlyTheCurrentRecoveryRecord() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let client = SourceClient(hook: { _, _ in
            let pending = try f.recoveryGuard.pendingRecord()
            #expect(pending != nil)
        })
        let service = f.service(client: client, desktop: SourceDesktop(failingReopens: [1]))
        let failure = try #require(await switchFailure(service, target: .chatGPT(f.b.id)))
        #expect(failure.previousSelectionRestored && failure.desktopReopened)
        #expect(try f.recoveryGuard.pendingRecord() == nil)
    }

    @Test func inheritedRecoveryRecordRemainsAfterFailedExplicitSwitch() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        try f.publishPendingRecord()
        let old = try SourceFileSnapshot.read(f.recoveryGuard.recordURL)
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(f.service(client: SourceClient(mismatchOn: 1), desktop: desktop), target: .chatGPT(f.b.id)))
        #expect(failure.sourceMutationAttempted)
        #expect(!failure.previousSelectionRestored && !failure.desktopReopened)
        #expect(await desktop.counts() == [1, 0])
        try old.requireUnchanged()
        #expect(throws: SourceSwitchRecoveryError.self) { try f.recoveryGuard.requireSafeAutomaticWork() }
    }

    @Test func inheritedRecoveryRecordClearsAfterSuccessfulExplicitSwitch() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        try f.publishPendingRecord()
        let freshStore = AccountStore(baseURL: f.registry.deletingLastPathComponent(), activeHomeURL: f.home)
        let service = SourceSwitchService(store: freshStore, codex: SourceClient(), desktop: SourceDesktop(), provider: f.provider)
        #expect(try await service.switchSource(to: .chatGPT(f.b.id)).accountID == f.b.id)
        #expect(try f.recoveryGuard.pendingRecord() == nil)
    }

    @Test func invalidRecoveryRecordFailsBeforeDesktopOrCredentialWork() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        try Data("invalid".utf8).write(to: f.recoveryGuard.recordURL)
        let before = try SourceFileSnapshot.read(f.auth)
        let desktop = SourceDesktop(), client = SourceClient()
        let failure = try #require(await switchFailure(f.service(client: client, desktop: desktop), target: .chatGPT(f.b.id)))
        #expect(failure.stage == .prepare && !failure.sourceMutationAttempted)
        #expect(await desktop.counts() == [0, 0])
        #expect(await client.verificationCalls() == 0)
        try before.requireUnchanged()
        #expect(try String(contentsOf: f.recoveryGuard.recordURL, encoding: .utf8) == "invalid")
    }

    @Test func differentHomeBindingFailsBeforeClosingDesktopForAPISwitch() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let otherHome = fixture.root.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: false)
        let desktop = SourceDesktop()
        let store = AccountStore(baseURL: fixture.registry.deletingLastPathComponent(), activeHomeURL: otherHome)
        let service = SourceSwitchService(store: store, codex: SourceClient(), desktop: desktop,
            provider: ProviderConfiguration(codexHome: otherHome))
        let before = try SourceFileSnapshot.read(fixture.registry)
        let failure = try #require(await switchFailure(service, target: .copilot))
        #expect(failure.stage == .prepare && !failure.sourceMutationAttempted)
        #expect(await desktop.counts() == [0, 0])
        try before.requireUnchanged()
        #expect(!FileManager.default.fileExists(atPath: otherHome.appendingPathComponent("config.toml").path))
    }

    @Test(arguments: [false, true])
    func normalSwitchAndFailureNeverOpenOrRewriteUnknownHistory(failReopen: Bool) async throws {
        let f = try await SourceFixture(provider: "copilot")
        defer { f.clean() }
        let rollout = try f.addSyntheticCopilotThread()
        let future = f.home.appending(path: "state_99.sqlite")
        let sidecar = f.home.appending(path: "state_99.sqlite-wal")
        let malformed = f.home.appending(path: "sessions/malformed.jsonl")
        let nested = f.home.appending(path: "sqlite/unknown.sqlite")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [future, sidecar, malformed, nested] { try Data("opaque history: not JSON or SQLite\n".utf8).write(to: file) }
        let files = [rollout, f.home.appending(path: "state_5.sqlite"), future, sidecar, malformed, nested]
        let original = try files.map { try Data(contentsOf: $0) }
        let relay = SourceRelay()
        let service = f.stableService(relay: relay, desktop: SourceDesktop(failingReopens: failReopen ? [1] : []))
        let preview = try await service.preview(to: .chatGPT(f.b.id))
        #expect(preview.sessionCount == 0 && preview.backupBytesUpperBound == 0 && preview.stableRouting)
        if failReopen {
            let failure = try #require(await switchFailure(service, target: .chatGPT(f.b.id)))
            #expect(failure.stage == .reopenDesktop && failure.previousSelectionRestored)
        } else {
            _ = try await service.switchSource(to: .chatGPT(f.b.id))
            _ = try await service.switchSource(to: .copilotWithoutOfficialIdentity)
            _ = try await service.restorePreviousSelection()
        }
        #expect(try files.map { try Data(contentsOf: $0) } == original)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "store/session-backups").path))
    }

    @Test(arguments: [false, true], [false, true])
    func survivingNativeWriterBlocksBeforeRelayIdentityAndConfigChanges(unchangedSessions: Bool, failReopen: Bool) async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let rollout = try fixture.addSyntheticCopilotThread()
        if unchangedSessions {
            let text = try String(contentsOf: rollout, encoding: .utf8).replacingOccurrences(of: "copilot", with: "openai")
            try Data(text.utf8).write(to: rollout)
            var db: OpaquePointer?
            guard sqlite3_open(fixture.home.appending(path: "state_5.sqlite").path, &db) == SQLITE_OK else { throw SourceTestError.injected }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "UPDATE threads SET model_provider='openai'", nil, nil, nil) == SQLITE_OK else { throw SourceTestError.injected }
        }
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let sourceFiles = [fixture.auth, fixture.config, fixture.registry, rollout,
            fixture.home.appending(path: "state_5.sqlite"),
            fixture.root.appending(path: "store/previous-source.json"),
            await fixture.store.profileHome(id: fixture.a.id).appending(path: "auth.json"),
            await fixture.store.profileHome(id: fixture.b.id).appending(path: "auth.json")]
        let originals = try sourceFiles.map { try SourceFileSnapshot.read($0) }
        let writer = TestFileWriter(file: fixture.home.appending(path: "state_5.sqlite"))
        defer { writer.stop() }
        let desktop = SourceDesktop(failingReopens: failReopen ? [1] : [],
            onClose: { count in if count == 1 { try writer.run() } })
        let relay = SourceRelay(), client = SourceClient()
        let target: SourceTarget = unchangedSessions ? .chatGPT(fixture.b.id) : .copilotWithIdentity(fixture.b.id)
        let failure = try #require(await switchFailure(fixture.stableService(relay: relay, client: client, desktop: desktop), target: target))
        #expect(failure.stage == .verifyQuiescence)
        #expect(failure.cause.contains("active writers"))
        #expect(!failure.sourceMutationAttempted)
        #expect(failure.previousSelectionRestored)
        #expect(failure.desktopReopened == !failReopen)
        #expect(failure.preservedCredentialFiles.isEmpty)
        #expect(failure.errorDescription?.contains("No source changes were made") == true)
        #expect(failure.errorDescription?.contains("could not be fully restored") == false)
        if failReopen {
            #expect(failure.recoveryErrors.count == 1)
            #expect(failure.recoveryErrors.first?.contains("Reopening the previous selection failed") == true)
        } else { #expect(failure.recoveryErrors.isEmpty) }
        #expect(await client.verificationCalls() == 0)
        #expect(await relay.startCount() == 0)
        #expect(try await relay.status()?.enabled == false)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appending(path: "auth.json")) == fixture.bBytes)
        for original in originals { try original.requireUnchanged() }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "store/credential-recovery").path))
        #expect(await desktop.counts() == [1, 1])
        #expect(writer.isRunning)
        #expect(try fixture.recoveryGuard.pendingRecord() == nil)
    }

    @Test func relayStartupAttemptBeforeCaptureStillRequiresQuiescentRecovery() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        _ = try fixture.addSyntheticCopilotThread()
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let writer = TestFileWriter(file: fixture.home.appending(path: "state_5.sqlite"))
        defer { writer.stop() }
        let relay = SourceRelay(onStart: { try writer.run(); throw SourceTestError.injected })
        let desktop = SourceDesktop(), client = SourceClient()
        let failure = try #require(await switchFailure(fixture.stableService(relay: relay, client: client, desktop: desktop), target: .copilotWithIdentity(fixture.b.id)))
        #expect(failure.stage == .verifyQuiescence)
        #expect(failure.sourceMutationAttempted)
        #expect(!failure.previousSelectionRestored && !failure.desktopReopened)
        #expect(failure.recoveryErrors.contains { $0.contains("active writers") })
        #expect(await relay.startCount() == 1)
        #expect(await client.verificationCalls() == 0)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(await desktop.counts() == [1, 0])
        #expect(writer.isRunning)
        #expect(try fixture.recoveryGuard.pendingRecord() != nil)
    }

    @Test func writerAppearingDuringIdentityVerificationBlocksRecoveryWritesAndReopen() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        _ = try fixture.addSyntheticCopilotThread()
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let writer = TestFileWriter(file: fixture.home.appending(path: "state_5.sqlite"))
        defer { writer.stop() }
        let client = SourceClient(hook: { _, _ in try writer.run(); throw SourceTestError.injected })
        let relay = SourceRelay(), desktop = SourceDesktop()
        let failure = try #require(await switchFailure(fixture.stableService(relay: relay, client: client, desktop: desktop), target: .copilotWithIdentity(fixture.b.id)))
        #expect(failure.stage == .verifyIdentity)
        #expect(failure.sourceMutationAttempted)
        #expect(!failure.previousSelectionRestored)
        #expect(failure.recoveryErrors.contains { $0.contains("active writers") })
        #expect(!failure.desktopReopened)
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
        #expect(try await fixture.provider.readRoute().logicalProvider == "copilot")
        #expect(try await relay.status()?.enabled == true)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(await desktop.counts() == [1, 0])
        #expect(writer.isRunning)
        #expect(try fixture.recoveryGuard.pendingRecord() != nil)
    }

    @Test func explicitPureAPISelectionCodableKeepsLegacyMissingIdentityDistinct() throws {
        let legacy = try JSONDecoder().decode(MenuSelection.self, from: Data("{\"provider\":\"copilot\"}".utf8))
        #expect(!legacy.officialIdentityDisabled)
        #expect(throws: SourceFileError.self) { try SourceTarget.restoring(legacy) }
        let selection = MenuSelection(provider: "copilot", accountID: UUID(), officialIdentityDisabled: true)
        #expect(selection.accountID == nil)
        let restored = try JSONDecoder().decode(MenuSelection.self, from: JSONEncoder().encode(selection))
        #expect(restored == selection)
        let conflicting = Data("{\"provider\":\"copilot\",\"accountID\":\"\(UUID())\",\"officialIdentityDisabled\":true}".utf8)
        #expect(try JSONDecoder().decode(MenuSelection.self, from: conflicting).accountID == nil)
        guard case .copilotWithoutOfficialIdentity = try SourceTarget.restoring(restored) else {
            Issue.record("Explicit pure API must restore without any official identity")
            return
        }
    }

    @Test func pureAPIBackAfterNativeBDoesNotBorrowBOrReverifyRevokedA() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceRelay()
        let client = SourceClient(mismatchOn: 1)
        let service = f.stableService(relay: relay, client: client)
        let pure = try await service.switchSource(to: .copilot)
        #expect(pure == MenuSelection(provider: "copilot", officialIdentityDisabled: true))
        #expect(try await service.currentSelection() == pure)
        _ = try await service.switchSource(to: .chatGPT(f.b.id))
        let previousURL = f.root.appending(path: "store").appending(path: "previous-source.json")
        let previous = try JSONDecoder().decode(MenuSelection.self, from: Data(contentsOf: previousURL))
        #expect(previous == pure)
        let verifications = await client.verificationCalls()
        #expect(try await service.restoreSelection(previous) == pure)
        #expect(await client.verificationCalls() == verifications)
        #expect(try await service.currentSelection() == pure)
        #expect(try Data(contentsOf: f.auth) == f.bBytes)
        #expect(try await f.store.loadRegistry().activeAccountID == f.b.id)
        #expect(try await f.provider.readRoute().physicalProvider == "copilot")
        #expect(try await relay.status()?.enabled == true)
    }

    @Test func stableRouteRestoresTheWholeCombinationAndPersistsBackEntry() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceRelay()
        let client = SourceClient()
        let service = f.stableService(relay: relay, client: client)
        let api = try await service.switchSource(to: .copilot)
        #expect(api == MenuSelection(provider: "copilot", accountID: f.a.id))
        #expect(try await f.provider.readRoute().physicalProvider == "openai")
        #expect(try await relay.status()?.enabled == true)
        _ = try await service.switchSource(to: .chatGPT(f.b.id))
        #expect(try await f.provider.readProvider() == "openai")
        #expect(try await relay.status()?.enabled == false)
        let saved = try JSONDecoder().decode(MenuSelection.self, from: Data(contentsOf: f.root.appending(path: "store").appending(path: "previous-source.json")))
        #expect(saved == api)
        #expect(try await service.restoreSelection(saved) == api)
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try await relay.status()?.enabled == true)
        #expect(await client.effectiveAuthCalls() == 3)
    }

    @Test func stableRouteVerificationFailureRestoresConfigIdentityAndRelay() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let original = try Data(contentsOf: f.config)
        let relay = SourceRelay()
        let service = f.stableService(relay: relay, client: SourceClient(mismatchOn: 1))
        let failure = await switchFailure(service, target: .copilotWithIdentity(f.b.id))
        #expect(failure?.stage == .verifyIdentity)
        #expect(failure?.previousSelectionRestored == true)
        #expect(try Data(contentsOf: f.config) == original)
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try await relay.status()?.enabled == false)
    }

    @Test func stableRouteReopenFailureLeavesHistoryBytesUntouched() async throws {
        let f = try await SourceFixture(provider: "copilot")
        defer { f.clean() }
        let rollout = try f.addSyntheticCopilotThread()
        let oldRollout = try Data(contentsOf: rollout)
        let oldState = try Data(contentsOf: f.home.appending(path: "state_5.sqlite"))
        let oldConfig = try Data(contentsOf: f.config)
        let relay = SourceRelay()
        let service = f.stableService(relay: relay, desktop: SourceDesktop(failingReopens: [1]))
        let failure = await switchFailure(service, target: .chatGPT(f.b.id))
        #expect(failure?.stage == .reopenDesktop)
        #expect(failure?.previousSelectionRestored == true)
        #expect(try Data(contentsOf: rollout) == oldRollout)
        #expect(try Data(contentsOf: f.config) == oldConfig)
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try Data(contentsOf: f.home.appending(path: "state_5.sqlite")) == oldState)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "store/session-backups").path))
    }

    @Test func stablePreviewDoesNotChangeConfigOrStartRelayAndQuitDrainsPooledSocket() async throws {
        let f = try await SourceFixture(provider: "copilot")
        defer { f.clean() }
        let rollout = try f.addSyntheticCopilotThread()
        let history = try Data(contentsOf: rollout)
        let state = try Data(contentsOf: f.home.appending(path: "state_5.sqlite"))
        let original = try Data(contentsOf: f.config)
        let relay = SourceRelay(busy: true)
        let desktop = SourceDesktop(onClose: { _ in await relay.clearBusy() })
        let service = f.stableService(relay: relay, desktop: desktop)
        let preview = try await service.preview(to: .copilotWithIdentity(f.a.id))
        #expect(preview.sessionCount == 0)
        #expect(preview.backupBytesUpperBound == 0)
        #expect(preview.stableRouting)
        #expect(try Data(contentsOf: f.config) == original)
        #expect(await relay.startCount() == 0)
        #expect(await desktop.counts() == [0, 0])
        _ = try await service.switchSource(to: .copilotWithIdentity(f.a.id))
        #expect(try Data(contentsOf: rollout) == history)
        #expect(try Data(contentsOf: f.home.appending(path: "state_5.sqlite")) == state)
    }

    @Test func stablePureAPINeverResurrectsMissingOfficialCredential() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        try FileManager.default.removeItem(at: f.auth)
        let relay = SourceRelay()
        let client = SourceClient()
        _ = try await f.stableService(relay: relay, client: client).switchSource(to: .copilot)
        #expect(!FileManager.default.fileExists(atPath: f.auth.path))
        #expect(try await f.provider.readRoute().physicalProvider == "copilot")
        #expect(await client.verificationCalls() == 0)
        #expect(await client.effectiveAuthCalls() == 1)
    }

    @Test func stableSimpleAPICanLeaveARevokedAccountWithoutClaimingAnIdentity() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceRelay()
        let client = SourceClient(mismatchOn: 1)
        let selected = try await f.stableService(relay: relay, client: client).switchSource(to: .copilot)
        #expect(selected.provider == "copilot")
        #expect(selected.accountID == nil)
        #expect(selected.officialIdentityDisabled)
        #expect(try Data(contentsOf: f.auth) == f.aBytes)
        #expect(try await f.provider.readRoute().physicalProvider == "copilot")
        #expect(try await relay.status()?.enabled == true)
    }

    @Test func nativeLogoutDuringQuitIsNotReplacedByThePreviouslySavedIdentity() async throws {
        let f = try await SourceFixture()
        defer { f.clean() }
        let relay = SourceRelay()
        let client = SourceClient()
        let desktop = SourceDesktop(onClose: { _ in try FileManager.default.removeItem(at: f.auth) })
        _ = try await f.stableService(relay: relay, client: client, desktop: desktop).switchSource(to: .copilot)
        #expect(!FileManager.default.fileExists(atPath: f.auth.path))
        #expect(try await f.provider.readRoute().physicalProvider == "copilot")
        #expect(await client.verificationCalls() == 0)
    }
    @Test func switchesAtoBAndCommitsBothPartsBeforeReopening() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let client = SourceClient()
        let desktop = SourceDesktop()
        let service = fixture.service(client: client, desktop: desktop)
        let result = try await service.switchSource(to: .chatGPT(fixture.b.id))
        #expect(result == MenuSelection(provider: "openai", accountID: fixture.b.id))
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.b.id)
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == fixture.aBytes)
        #expect(await desktop.counts() == [1, 1])
        #expect(await client.verificationCalls() == 1)
        #expect(await client.usedPrivateHomes(avoiding: fixture.home))
    }

    @Test func copilotPreservesOAuthAndLastChatGPTThenCanReturnToEitherAccount() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let service = fixture.service()
        let api = try await service.switchSource(to: .copilot)
        #expect(api == MenuSelection(provider: "copilot", accountID: fixture.a.id))
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try await fixture.store.loadRegistry().accounts.count == 2)
        #expect(try await service.currentSelection() == api)
        _ = try await service.switchSource(to: .chatGPT(fixture.a.id))
        #expect(try await service.currentSelection() == MenuSelection(provider: "openai", accountID: fixture.a.id))
        _ = try await service.switchSource(to: .copilot)
        _ = try await service.switchSource(to: .chatGPT(fixture.b.id))
        #expect(try await service.currentSelection() == MenuSelection(provider: "openai", accountID: fixture.b.id))
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
    }

    @Test func restoresCopilotAndItsSpecificIdentityAfterUsingAnotherNativeAccount() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let client = SourceClient()
        let desktop = SourceDesktop()
        let service = fixture.service(client: client, desktop: desktop)
        let original = try await service.switchSource(to: .copilotWithIdentity(fixture.a.id))
        let originalConfig = try Data(contentsOf: fixture.config)
        #expect(original == MenuSelection(provider: "copilot", accountID: fixture.a.id))
        #expect(await desktop.counts() == [1, 1])
        _ = try await service.switchSource(to: .chatGPT(fixture.b.id))
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
        let restored = try await service.restoreSelection(original)
        #expect(restored == original)
        #expect(try await service.currentSelection() == original)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(await desktop.counts() == [3, 3])
        #expect(await client.verificationCalls() == 3)
        #expect(await client.effectiveAuthCalls() == 2)
    }

    @Test func selectingTheSameCopilotIdentityRepairsItsConfigurationAndVerifiesIt() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let client = SourceClient()
        let desktop = SourceDesktop()
        let selection = try await fixture.service(client: client, desktop: desktop).switchSource(to: .copilotWithIdentity(fixture.a.id))
        let appliedConfig = try Data(contentsOf: fixture.config)
        #expect(selection == MenuSelection(provider: "copilot", accountID: fixture.a.id))
        #expect(await client.effectiveConfigurations() == [appliedConfig])
        #expect(String(decoding: appliedConfig, as: UTF8.self).contains("requires_openai_auth = true"))
        #expect(String(decoding: appliedConfig, as: UTF8.self).contains("experimental_bearer_token = \"local\""))
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(await desktop.counts() == [1, 1])
        #expect(await client.usedPrivateHomes(avoiding: fixture.home))
    }

    @Test func explicitCopilotIdentityRestoresSavedAccountAfterNativeLogout() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        let client = SourceClient()
        let desktop = SourceDesktop()
        let service = fixture.service(client: client, desktop: desktop)
        let selection = try await service.switchSource(to: .copilotWithIdentity(fixture.a.id))
        #expect(selection == MenuSelection(provider: "copilot", accountID: fixture.a.id))
        #expect(try await service.currentSelection() == selection)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(await client.verificationCalls() == 1)
        #expect(await client.effectiveAuthCalls() == 1)
        #expect(await client.effectiveConfigurations() == [try Data(contentsOf: fixture.config)])
        #expect(await desktop.counts() == [1, 1])
    }

    @Test func explicitCopilotIdentityRequiresEffectiveChatGPTIdentityAndAuthMode() async throws {
        let goodIdentity = AccountIdentity(accountID: "B", email: "b@example.test")
        let invalidStatuses = [
            EffectiveAuthStatus(authMethod: nil, requiresOpenaiAuth: true, identity: goodIdentity),
            EffectiveAuthStatus(authMethod: "apikey", requiresOpenaiAuth: true, identity: goodIdentity),
            EffectiveAuthStatus(authMethod: "chatgpt", requiresOpenaiAuth: false, identity: goodIdentity),
            EffectiveAuthStatus(authMethod: "chatgpt", requiresOpenaiAuth: true, identity: nil),
            EffectiveAuthStatus(authMethod: "chatgpt", requiresOpenaiAuth: true,
                identity: AccountIdentity(accountID: "other", email: "b@example.test"))
        ]
        for status in invalidStatuses {
            let fixture = try await SourceFixture()
            defer { fixture.clean() }
            let originalConfig = try Data(contentsOf: fixture.config)
            let originalRegistry = try Data(contentsOf: fixture.registry)
            let client = SourceClient(effectiveHook: { _, _ in status })
            let failure = try #require(await switchFailure(fixture.service(client: client), target: .copilotWithIdentity(fixture.b.id)))
            #expect(failure.stage == .verifyIdentity)
            #expect(failure.previousSelectionRestored)
            #expect(try Data(contentsOf: fixture.config) == originalConfig)
            #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
            #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        }
    }

    @Test func copilotIdentityValidationPreservesBothNativeAndEffectiveTokenRotations() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let nativeRefresh = sourceAuth("B", token: "native-refresh")
        let effectiveRefresh = sourceAuth("B", token: "effective-config-refresh")
        let client = SourceClient(hook: { _, home in
            try nativeRefresh.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
        }, effectiveHook: { _, home in
            #expect(try Data(contentsOf: home.appendingPathComponent("auth.json")) == nativeRefresh)
            try effectiveRefresh.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            return nil
        })
        _ = try await fixture.service(client: client).switchSource(to: .copilotWithIdentity(fixture.b.id))
        #expect(try Data(contentsOf: fixture.auth) == effectiveRefresh)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == effectiveRefresh)
        #expect(await client.effectiveConfigurations() == [try Data(contentsOf: fixture.config)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("store/credential-recovery").path).isEmpty)
    }

    @Test(arguments: [false, true])
    func failedEffectiveProbePreservesNewestCredentialAndReportsOriginalRecoveryRequirement(sameAccount: Bool) async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let target = sameAccount ? fixture.a : fixture.b
        let refreshed = sourceAuth(sameAccount ? "A" : "B", token: "effective-probe-failed-after-refresh")
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let client = SourceClient(effectiveHook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            throw SourceTestError.injected
        })
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(fixture.service(client: client, desktop: desktop), target: .copilotWithIdentity(target.id)))
        #expect(failure.stage == .verifyIdentity)
        #expect(failure.previousSelectionRestored == !sameAccount)
        #expect(failure.desktopReopened == !sameAccount)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == refreshed)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: target.id).appendingPathComponent("auth.json")) == (sameAccount ? fixture.aBytes : fixture.bBytes))
        #expect(await desktop.counts() == [1, sameAccount ? 0 : 1])
    }

    @Test func copilotIdentityReopenFailureRestoresEveryOriginalConfigurationByte() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let failure = try #require(await switchFailure(fixture.service(desktop: SourceDesktop(failingReopens: [1])), target: .copilotWithIdentity(fixture.b.id)))
        #expect(failure.stage == .reopenDesktop)
        #expect(failure.previousSelectionRestored)
        #expect(failure.desktopReopened)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func effectiveProbeConcurrentConfigurationEditIsPreserved() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let external = Data("model_provider = \"openai\"\n# another writer owns these bytes\n".utf8)
        let refreshed = sourceAuth("B", token: "refresh-before-external-config-edit")
        let client = SourceClient(effectiveHook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            try external.write(to: fixture.config, options: .atomic)
            return nil
        })
        let failure = try #require(await switchFailure(fixture.service(client: client), target: .copilotWithIdentity(fixture.b.id)))
        #expect(failure.stage == .verifyIdentity)
        #expect(!failure.previousSelectionRestored)
        #expect(!failure.desktopReopened)
        #expect(try Data(contentsOf: fixture.config) == external)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == refreshed)
    }

    @Test func effectiveCopilotProbeKeepsTheTransactionLockAcrossBothIdentityChecks() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let gate = SourceGate()
        let client = SourceClient(effectiveHook: { _, _ in await gate.pause(); return nil })
        let first = fixture.service(client: client)
        let second = fixture.service()
        let task = Task { try await first.switchSource(to: .copilotWithIdentity(fixture.b.id)) }
        await gate.waitUntilPaused()
        await #expect(throws: SourceFileError.self) { try await first.switchSource(to: .copilot) }
        await #expect(throws: SourceFileError.self) {
            try await second.restoreSelection(MenuSelection(provider: "copilot", accountID: fixture.a.id))
        }
        await gate.resume()
        #expect(try await task.value == MenuSelection(provider: "copilot", accountID: fixture.b.id))
    }

    @Test func incompleteSavedSelectionCannotBorrowTheCurrentIdentityOrDeleteItsAuth() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let desktop = SourceDesktop()
        let service = fixture.service(desktop: desktop)
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalRegistry = try Data(contentsOf: fixture.registry)
        for provider in ["openai", "copilot"] {
            await #expect(throws: SourceFileError.self) {
                try await service.restoreSelection(MenuSelection(provider: provider, accountID: nil))
            }
        }
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(await desktop.counts() == [0, 0])
    }

    @Test func copilotWithoutAnyCurrentIdentityDoesNotInventOneFromSavedAccounts() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        var registry = try await fixture.store.loadRegistry()
        registry.activeAccountID = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(registry).write(to: fixture.registry, options: .atomic)
        let client = SourceClient(hook: { _, _ in throw SourceTestError.injected },
            effectiveHook: { _, _ in throw SourceTestError.injected })
        let selection = try await fixture.service(client: client).switchSource(to: .copilot)
        #expect(selection == MenuSelection(provider: "copilot", accountID: nil))
        #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
        #expect(try await fixture.store.reloadRegistry().activeAccountID == nil)
        #expect(try await fixture.store.loadRegistry().accounts.count == 2)
        #expect(await client.verificationCalls() == 0)
        #expect(await client.effectiveAuthCalls() == 0)
    }

    @Test func unsupportedCopilotConfigurationFailsBeforeDesktopQuitOrAuthMutation() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let config = Data("model_provider = \"openai\"\n[model_providers.copilot]\nbase_url = \"https://unexpected.example/v1\"\n".utf8)
        try config.write(to: fixture.config, options: .atomic)
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(fixture.service(desktop: desktop), target: .copilotWithIdentity(fixture.b.id)))
        #expect(failure.stage == .prepare)
        #expect(failure.previousSelectionRestored)
        #expect(await desktop.counts() == [0, 0])
        #expect(try Data(contentsOf: fixture.config) == config)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func capturesLastOAuthWriteAfterNormalQuit() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let fresh = sourceAuth("A", token: "after-normal-quit")
        let desktop = SourceDesktop(onClose: { number in
            if number == 1 { try fresh.write(to: fixture.auth, options: .atomic) }
        })
        _ = try await fixture.service(desktop: desktop).switchSource(to: .chatGPT(fixture.b.id))
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == fresh)
    }

    @Test func tokenRefreshIsSavedForOriginalAndTarget() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let refreshedA = sourceAuth("A", token: "refreshed-A")
        let refreshedB = sourceAuth("B", token: "refreshed-B")
        let desktop = SourceDesktop(onClose: { _ in try refreshedA.write(to: fixture.auth, options: .atomic) })
        let client = SourceClient(hook: { _, home in
            try refreshedB.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
        })
        _ = try await fixture.service(client: client, desktop: desktop).switchSource(to: .chatGPT(fixture.b.id))
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == refreshedA)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == refreshedB)
        #expect(try Data(contentsOf: fixture.auth) == refreshedB)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("store/credential-recovery").path).isEmpty)
    }

    @Test func mismatchedTargetRestoresIdentityProviderAndRegistry() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let originalRegistry = try Data(contentsOf: fixture.registry)
        let originalConfig = try Data(contentsOf: fixture.config)
        let desktop = SourceDesktop()
        let failure = await switchFailure(fixture.service(client: SourceClient(mismatchOn: 1), desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.stage == .verifyIdentity)
        #expect(failure?.previousSelectionRestored == true)
        #expect(failure?.desktopReopened == true)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
        #expect(await desktop.counts() == [1, 1])
    }

    @Test func upstreamVerificationFailureAlsoRollsBack() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let client = SourceClient(hook: { _, _ in throw SourceTestError.injected })
        let failure = await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.b.id))
        #expect(failure?.stage == .verifyIdentity)
        #expect(failure?.previousSelectionRestored == true)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func failedRefreshOfOriginalAccountKeepsPrivateRecoveryAndDoesNotClaimRestoration() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let refreshed = sourceAuth("A", token: "unique-new-original-refresh")
        let client = SourceClient(hook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            throw SourceTestError.injected
        })
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(fixture.service(client: client, desktop: desktop), target: .chatGPT(fixture.a.id)))
        let recoveryFile = try #require(failure.preservedCredentialFiles.first)
        #expect(failure.stage == .verifyIdentity)
        #expect(!failure.previousSelectionRestored)
        #expect(!failure.desktopReopened)
        #expect(try Data(contentsOf: recoveryFile) == refreshed)
        #expect(recoveryFile.path.hasPrefix(fixture.root.appendingPathComponent("store/credential-recovery").path))
        #expect(try (FileManager.default.attributesOfItem(atPath: recoveryFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try (FileManager.default.attributesOfItem(atPath: recoveryFile.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == fixture.aBytes)
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(await desktop.counts() == [1, 0])
        #expect(failure.errorDescription?.contains(recoveryFile.path) == true)
        #expect(failure.errorDescription?.contains("unique-new-original-refresh") == false)
    }

    @Test func failedTargetRefreshKeepsNewestBundleWhileRestoringOriginalAccount() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let refreshed = sourceAuth("B", token: "unique-new-target-refresh")
        let client = SourceClient(hook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            throw SourceTestError.injected
        })
        let desktop = SourceDesktop()
        let failure = try #require(await switchFailure(fixture.service(client: client, desktop: desktop), target: .chatGPT(fixture.b.id)))
        #expect(failure.previousSelectionRestored)
        #expect(failure.desktopReopened)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == refreshed)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == fixture.bBytes)
        #expect(await desktop.counts() == [1, 1])
    }

    @Test func changedWrongIdentityIsQuarantinedWithoutAssociatingItWithTargetProfile() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let wrong = sourceAuth("other-account", token: "never-associate-this")
        let client = SourceClient(hook: { _, home in try wrong.write(to: home.appendingPathComponent("auth.json"), options: .atomic) })
        let failure = try #require(await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.b.id)))
        #expect(failure.previousSelectionRestored)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == wrong)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == fixture.bBytes)
    }

    @Test func refreshedCredentialIsAlsoRetainedWhenPostVerificationProfileCASFails() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let targetFile = await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")
        let refreshed = sourceAuth("B", token: "verified-but-not-yet-saved")
        let external = sourceAuth("B", token: "external-profile-update")
        let client = SourceClient(hook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            try external.write(to: targetFile, options: .atomic)
        })
        let failure = try #require(await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.b.id)))
        #expect(failure.previousSelectionRestored)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == refreshed)
        #expect(try Data(contentsOf: targetFile) == external)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func revokedCurrentAccountCanLeaveForCopilotWithoutAnUpstreamCall() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let client = SourceClient(hook: { _, _ in throw SourceTestError.injected })
        let selection = try await fixture.service(client: client).switchSource(to: .copilot)
        #expect(selection == MenuSelection(provider: "copilot", accountID: fixture.a.id))
        #expect(await client.verificationCalls() == 0)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func revokedCurrentAccountCanLeaveForAValidTargetAccount() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let client = SourceClient(hook: { _, home in
            if try Data(contentsOf: home.appendingPathComponent("auth.json")) == fixture.aBytes { throw SourceTestError.injected }
        })
        let selection = try await fixture.service(client: client).switchSource(to: .chatGPT(fixture.b.id))
        #expect(selection == MenuSelection(provider: "openai", accountID: fixture.b.id))
        #expect(await client.verificationCalls() == 1)
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
    }

    @Test func nativeLogoutCanSwitchSourcesWithoutRestoringAnOldSavedLogin() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        let service = fixture.service()
        _ = try await service.switchSource(to: .copilot)
        #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        _ = try await service.switchSource(to: .chatGPT(fixture.b.id))
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
    }

    @Test func failedTargetAfterNativeLogoutRestoresMissingAuthFile() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        let failure = try #require(await switchFailure(fixture.service(client: SourceClient(mismatchOn: 1)), target: .chatGPT(fixture.b.id)))
        #expect(failure.previousSelectionRestored)
        #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
    }

    @Test func failedRefreshAfterNativeLogoutPreservesBothRecoveryFileAndUnsignedInState() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        let refreshed = sourceAuth("A", token: "refresh-while-previously-signed-out")
        let client = SourceClient(hook: { _, home in
            try refreshed.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
            throw SourceTestError.injected
        })
        let failure = try #require(await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.a.id)))
        #expect(failure.previousSelectionRestored)
        #expect(failure.desktopReopened)
        #expect(try Data(contentsOf: #require(failure.preservedCredentialFiles.first)) == refreshed)
        #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
        #expect(try await fixture.provider.readProvider() == "copilot")
    }

    @Test func writeFailureLeavesOriginalSelectionAndReportsTheStage() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.home.path)
            fixture.clean()
        }
        let desktop = SourceDesktop(onClose: { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.home.path)
        })
        let failure = await switchFailure(fixture.service(desktop: desktop), target: .chatGPT(fixture.a.id))
        #expect(failure?.stage == .setProvider)
        #expect(failure?.previousSelectionRestored == true)
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func quitFailureDoesNotMutateTheThreeStateFiles() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let registry = try Data(contentsOf: fixture.registry)
        let config = try Data(contentsOf: fixture.config)
        let desktop = SourceDesktop(failingCloses: [1])
        let failure = await switchFailure(fixture.service(desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.stage == .closeDesktop)
        #expect(try Data(contentsOf: fixture.registry) == registry)
        #expect(try Data(contentsOf: fixture.config) == config)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(await desktop.counts() == [1, 0])
    }

    @Test func reopenFailureRollsBackCommittedRegistryAndReopensOriginal() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let registry = try Data(contentsOf: fixture.registry)
        let desktop = SourceDesktop(failingReopens: [1])
        let failure = await switchFailure(fixture.service(desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.stage == .reopenDesktop)
        #expect(failure?.previousSelectionRestored == true)
        #expect(failure?.desktopReopened == true)
        #expect(try Data(contentsOf: fixture.registry) == registry)
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(await desktop.counts() == [2, 2])
    }

    @Test func partialReopenThatCannotQuitNeverWritesUnderRunningApplication() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let desktop = SourceDesktop(failingCloses: [2], failingReopens: [1])
        let failure = await switchFailure(fixture.service(desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.previousSelectionRestored == false)
        #expect(failure?.desktopReopened == false)
        #expect(failure?.recoveryErrors.isEmpty == false)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.b.id)
        #expect(try Data(contentsOf: fixture.auth) == fixture.bBytes)
    }

    @Test func concurrentConfigEditIsPreservedWhileOwnedAuthRollsBack() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let external = Data("model_provider = \"external\"\n# another process\n".utf8)
        let client = SourceClient(hook: { _, _ in try external.write(to: fixture.config, options: .atomic) })
        let desktop = SourceDesktop()
        let failure = await switchFailure(fixture.service(client: client, desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.previousSelectionRestored == false)
        #expect(try Data(contentsOf: fixture.config) == external)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(await desktop.counts() == [1, 0])
    }

    @Test func concurrentAuthEditIsNeverCopiedIntoSavedProfileOrOverwritten() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let external = sourceAuth("external", token: "separate-login")
        let client = SourceClient(hook: { _, _ in try external.write(to: fixture.auth, options: .atomic) })
        let failure = await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.b.id))
        #expect(failure?.previousSelectionRestored == false)
        #expect(try Data(contentsOf: fixture.auth) == external)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == fixture.bBytes)
        #expect(try await fixture.provider.readProvider() == "copilot")
    }

    @Test func externalRegistryEditSurvivesRollback() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let external = try Data(contentsOf: fixture.registry) + Data("\n ".utf8)
        let client = SourceClient(hook: { _, _ in try external.write(to: fixture.registry, options: .atomic) })
        let failure = await switchFailure(fixture.service(client: client), target: .chatGPT(fixture.b.id))
        #expect(failure?.previousSelectionRestored == false)
        #expect(try Data(contentsOf: fixture.registry) == external)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
    }

    @Test func missingOAuthFieldAndAPIKeyOnlyCredentialAreRejected() async throws {
        for bad in [Data("{\"OPENAI_API_KEY\":\"fixture-only-key\"}".utf8), sourceAuth("A", omit: "refresh_token")] {
            let fixture = try await SourceFixture()
            defer { fixture.clean() }
            try bad.write(to: fixture.auth)
            let failure = await switchFailure(fixture.service(), target: .copilot)
            #expect(failure?.stage == .saveCurrentCredential)
            #expect(try Data(contentsOf: fixture.auth) == bad)
            #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == fixture.aBytes)
        }
    }

    @Test func strictStoreImportAndSaveRejectDifferentAccountCredential() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        try fixture.bBytes.write(to: fixture.auth)
        await #expect(throws: AccountStoreError.self) { try await fixture.store.saveCurrentCredential() }
        await #expect(throws: AccountStoreError.self) {
            try await fixture.store.registerActiveIdentity(AccountIdentity(accountID: "A", email: "a@example.test"))
        }
        let unregistered = AccountProfile(id: UUID(), displayName: "C", email: "c@example.test", accountID: "C", createdAt: Date())
        await #expect(throws: AccountStoreError.self) { try await fixture.store.importCurrentProfile(unregistered) }
        #expect(try await fixture.store.loadRegistry().accounts.count == 2)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == fixture.aBytes)
    }

    @Test func targetWithTheExpectedAccountIDButAnotherUserEmailIsNotInstalled() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let target = await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")
        let wrongUser = syntheticOAuthCredential(accountID: "B", email: "other-user@example.test")
        try wrongUser.write(to: target, options: .atomic)
        let failure = try #require(await switchFailure(fixture.service(), target: .chatGPT(fixture.b.id)))
        #expect(failure.stage == .activateCredential)
        #expect(failure.previousSelectionRestored)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: target) == wrongUser)
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
    }

    @Test func incompleteRegistryIsRejectedBeforeCredentialMutation() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let broken = Data("{\"activeAccountID\":null}".utf8)
        let desktop = SourceDesktop(onClose: { _ in try broken.write(to: fixture.registry, options: .atomic) })
        let failure = await switchFailure(fixture.service(desktop: desktop), target: .chatGPT(fixture.b.id))
        #expect(failure?.stage == .captureState)
        #expect(try Data(contentsOf: fixture.auth) == fixture.aBytes)
        #expect(try Data(contentsOf: fixture.registry) == broken)
    }

    @Test func sameAccountRefreshSurvivesFailedReopen() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        let latest = sourceAuth("A", token: "second-refresh")
        let client = SourceClient(hook: { _, home in
            try latest.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
        })
        let failure = await switchFailure(fixture.service(client: client, desktop: SourceDesktop(failingReopens: [1])), target: .chatGPT(fixture.a.id))
        #expect(failure?.previousSelectionRestored == true)
        #expect(try Data(contentsOf: fixture.auth) == latest)
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == latest)
    }

    @Test func sameAccountRefreshAfterNativeLogoutRestoresMissingAuthOnFailedReopen() async throws {
        let fixture = try await SourceFixture(provider: "copilot")
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.auth)
        let latest = sourceAuth("A", token: "refresh-after-native-logout")
        let client = SourceClient(hook: { _, home in
            try latest.write(to: home.appendingPathComponent("auth.json"), options: .atomic)
        })
        let failure = try #require(await switchFailure(fixture.service(client: client, desktop: SourceDesktop(failingReopens: [1])), target: .chatGPT(fixture.a.id)))
        #expect(failure.stage == .reopenDesktop)
        #expect(failure.previousSelectionRestored)
        #expect(failure.desktopReopened)
        #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.a.id)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.a.id).appendingPathComponent("auth.json")) == latest)
    }

    @Test func renameChangesOnlyTheDisplayNameAndKeepsCredentials() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let original = try await fixture.store.loadRegistry()
        try await fixture.store.renameAccount(id: fixture.b.id, displayName: "  Research account  ")
        var expected = original
        expected.accounts[1].displayName = "Research account"
        #expect(try await fixture.store.loadRegistry() == expected)
        #expect(try Data(contentsOf: await fixture.store.profileHome(id: fixture.b.id).appendingPathComponent("auth.json")) == fixture.bBytes)
    }

    @Test func sameServiceAndIndependentInstanceRejectConcurrentSwitches() async throws {
        let fixture = try await SourceFixture()
        defer { fixture.clean() }
        let gate = SourceGate()
        let client = SourceClient(hook: { call, _ in if call == 1 { await gate.pause() } })
        let first = fixture.service(client: client)
        let second = fixture.service()
        let task = Task { try await first.switchSource(to: .chatGPT(fixture.b.id)) }
        await gate.waitUntilPaused()
        await #expect(throws: SourceFileError.self) { try await first.switchSource(to: .copilot) }
        await #expect(throws: SourceFileError.self) { try await second.switchSource(to: .copilot) }
        await gate.resume()
        _ = try await task.value
        #expect(try await second.currentSelection() == MenuSelection(provider: "openai", accountID: fixture.b.id))
    }
}

private func switchFailure(_ service: SourceSwitchService, target: SourceTarget) async -> SourceSwitchFailure? {
    do { _ = try await service.switchSource(to: target); Issue.record("Expected the switch to fail"); return nil }
    catch let failure as SourceSwitchFailure { return failure }
    catch { Issue.record("Expected SourceSwitchFailure, got \(error)"); return nil }
}

private func sourceAuth(_ id: String, token: String = "fixture-token", omit: String? = nil) -> Data {
    var tokens = ["account_id": id, "id_token": syntheticIDToken(email: "\(id.lowercased())@example.test", accountID: id, tag: token), "access_token": "access-\(id)-\(token)", "refresh_token": "refresh-\(id)-\(token)"]
    if let omit { tokens.removeValue(forKey: omit) }
    return try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": tokens], options: [.sortedKeys])
}

private struct SourceFixture: Sendable {
    let root: URL, home: URL, auth: URL, config: URL, registry: URL
    let store: AccountStore
    let provider: ProviderConfiguration
    let a: AccountProfile, b: AccountProfile
    let aBytes: Data, bBytes: Data
    var recoveryGuard: SwitchRecoveryGuard { SwitchRecoveryGuard(baseURL: registry.deletingLastPathComponent(), home: home) }
    func publishPendingRecord() throws {
        let lock = try SourceSwitchLock(home: home)
        defer { lock.release() }
        _ = try recoveryGuard.begin(recoveryGuard.prepare(lock: lock), lock: lock)
    }
    init(provider selectedProvider: String = "openai") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("source-switch-test-\(UUID())")
        home = root.appendingPathComponent("active")
        auth = home.appendingPathComponent("auth.json")
        config = home.appendingPathComponent("config.toml")
        let base = root.appendingPathComponent("store")
        registry = base.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("# personal config\nmodel_provider = \"\(selectedProvider)\"\n[skills]\nkeep = true\n[mcp_servers.sample]\ncommand = \"keep-exact\"\n[model_providers.copilot]\nname = \"Copilot\"\nbase_url = \"http://127.0.0.1:4141/v1\"\n".utf8).write(to: config)
        store = AccountStore(baseURL: base, activeHomeURL: home)
        provider = ProviderConfiguration(codexHome: home)
        a = AccountProfile(id: UUID(), displayName: "A", email: "a@example.test", accountID: "A", createdAt: Date())
        b = AccountProfile(id: UUID(), displayName: "B", email: "b@example.test", accountID: "B", createdAt: Date())
        aBytes = sourceAuth("A"); bBytes = sourceAuth("B")
        let aHome = try await store.createProfileDirectory(id: a.id)
        try aBytes.write(to: aHome.appendingPathComponent("auth.json"))
        try await store.addProfile(a)
        let bHome = try await store.createProfileDirectory(id: b.id)
        try bBytes.write(to: bHome.appendingPathComponent("auth.json"))
        try await store.addProfile(b)
        try aBytes.write(to: auth)
        try await store.commitActiveAccountID(a.id)
    }
    func service(client: any AccountClient = SourceClient(), desktop: any DesktopControlling = SourceDesktop()) -> SourceSwitchService {
        SourceSwitchService(store: store, codex: client, desktop: desktop, provider: provider)
    }
    func stableService(relay: any APIRelayControlling, client: any AccountClient = SourceClient(), desktop: any DesktopControlling = SourceDesktop()) -> SourceSwitchService {
        SourceSwitchService(store: store, codex: client, desktop: desktop, provider: provider,
            relay: relay, activityGuard: CodexActivityGuard(home: home))
    }
    func configureManagedAPI() async throws {
        let before = try await provider.snapshot()
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: true, expecting: before)
    }
    func addSyntheticCopilotThread() throws -> URL {
        let id = UUID().uuidString.lowercased()
        let directory = home.appending(path: "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let rollout = directory.appending(path: "rollout-\(id).jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"model_provider\":\"copilot\"}}\n{\"type\":\"response_item\",\"payload\":{\"text\":\"unchanged fixture\"}}\n".utf8).write(to: rollout)
        var db: OpaquePointer?
        guard sqlite3_open(home.appending(path: "state_5.sqlite").path, &db) == SQLITE_OK else { throw SourceTestError.injected }
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, rollout_path TEXT); INSERT INTO threads VALUES('\(id)','copilot','\(rollout.path)');"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SourceTestError.injected }
        return rollout
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private enum SourceTestError: Error { case injected }

private actor SourceClient: AccountClient {
    var count = 0
    var verificationCount = 0
    var effectiveCount = 0
    var configurations: [Data] = []
    var homes: [URL] = []
    let mismatchOn: Int?
    let hook: @Sendable (Int, URL) async throws -> Void
    let effectiveHook: @Sendable (Int, URL) async throws -> EffectiveAuthStatus?
    init(mismatchOn: Int? = nil, hook: @escaping @Sendable (Int, URL) async throws -> Void = { _, _ in },
         effectiveHook: @escaping @Sendable (Int, URL) async throws -> EffectiveAuthStatus? = { _, _ in nil }) {
        self.mismatchOn = mismatchOn; self.hook = hook; self.effectiveHook = effectiveHook
    }
    func verificationCalls() -> Int { verificationCount }
    func effectiveAuthCalls() -> Int { effectiveCount }
    func effectiveConfigurations() -> [Data] { configurations }
    func usedPrivateHomes(avoiding activeHome: URL) -> Bool { !homes.isEmpty && homes.allSatisfy { $0 != activeHome } }
    func verifyIdentity(profileHome: URL) async throws -> AccountIdentity {
        verificationCount += 1
        return try await readIdentity(profileHome: profileHome)
    }
    func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        count += 1
        homes.append(profileHome)
        let call = count
        try await hook(call, profileHome)
        if call == mismatchOn { return AccountIdentity(accountID: "different-account", email: "different@example.test") }
        return try identityFromAuth(profileHome: profileHome)
    }
    func readEffectiveAuthStatus(profileHome: URL) async throws -> EffectiveAuthStatus {
        effectiveCount += 1
        homes.append(profileHome)
        configurations.append(try Data(contentsOf: profileHome.appendingPathComponent("config.toml")))
        if let status = try await effectiveHook(effectiveCount, profileHome) { return status }
        let route = try await ProviderConfiguration(codexHome: profileHome).readRoute()
        if route.isManaged && route.physicalProvider == "copilot" {
            return EffectiveAuthStatus(authMethod: nil, requiresOpenaiAuth: false, identity: nil)
        }
        return EffectiveAuthStatus(authMethod: "chatgpt", requiresOpenaiAuth: true,
            identity: try identityFromAuth(profileHome: profileHome))
    }
    private func identityFromAuth(profileHome: URL) throws -> AccountIdentity {
        let bytes = try Data(contentsOf: profileHome.appendingPathComponent("auth.json"))
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let id = (object["tokens"] as! [String: String])["account_id"]!
        return AccountIdentity(accountID: id, email: "\(id.lowercased())@example.test")
    }
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage { throw SourceTestError.injected }
    func login(profileHome: URL) async throws -> AccountIdentity { throw SourceTestError.injected }
}

private actor SourceDesktop: DesktopControlling {
    var closes = 0, reopens = 0
    var stopped = false
    let failingCloses: Set<Int>, failingReopens: Set<Int>
    let onClose: @Sendable (Int) async throws -> Void
    init(failingCloses: Set<Int> = [], failingReopens: Set<Int> = [], onClose: @escaping @Sendable (Int) async throws -> Void = { _ in }) {
        self.failingCloses = failingCloses; self.failingReopens = failingReopens; self.onClose = onClose
    }
    func counts() -> [Int] { [closes, reopens] }
    func closeDesktop() async throws {
        closes += 1
        if failingCloses.contains(closes) { throw SourceTestError.injected }
        try await onClose(closes)
        stopped = true
    }
    func reopenDesktop() async throws {
        reopens += 1
        if failingReopens.contains(reopens) { throw SourceTestError.injected }
        stopped = false
    }
    func isDesktopStopped() async throws -> Bool { stopped }
}

private actor SourceRelay: APIRelayControlling {
    private var enabled = false, busy: Bool
    private var starts = 0
    private let id = UUID().uuidString
    private let onStart: @Sendable () async throws -> Void
    init(busy: Bool = false, onStart: @escaping @Sendable () async throws -> Void = {}) {
        self.busy = busy; self.onStart = onStart
    }
    func status() async throws -> APIRelayStatus? { value() }
    func ensureRunning() async throws -> APIRelayStatus {
        starts += 1
        try await onStart()
        return value()
    }
    func setEnabled(_ value: Bool) async throws -> APIRelayStatus {
        if busy { throw APIRelayError.busy }
        enabled = value; return self.value()
    }
    func clearBusy() { busy = false }
    func startCount() -> Int { starts }
    private func value() -> APIRelayStatus {
        APIRelayStatus(protocolVersion: 1, pid: 123, instanceId: id, host: "127.0.0.1", port: 4142,
            baseURL: "http://127.0.0.1:4142/v1", enabled: enabled, activeRequests: 0,
            activeWebSockets: busy ? 1 : 0, testMode: false, upstreamPort: 4141)
    }
}

private actor SourceUpgradingRelay: APIRelayControlling {
    private var enabled: Bool
    private var available: Bool
    private var id = UUID().uuidString
    private var upgrades = 0, restarts = 0
    private let failUpgradeAfterShutdown: Bool
    private let failRestart: Bool

    init(enabled: Bool = false, initiallyPresent: Bool = true, failUpgradeAfterShutdown: Bool = false, failRestart: Bool = false) {
        self.enabled = enabled
        available = initiallyPresent
        self.failUpgradeAfterShutdown = failUpgradeAfterShutdown
        self.failRestart = failRestart
    }

    func status() async throws -> APIRelayStatus? { available ? value() : nil }
    func ensureRunningForSourceSwitch() async throws -> APIRelayStatus {
        upgrades += 1
        available = false
        enabled = false
        if failUpgradeAfterShutdown { throw SourceTestError.injected }
        available = true
        id = UUID().uuidString
        return value()
    }
    func ensureRunning() async throws -> APIRelayStatus {
        restarts += 1
        if failRestart { throw SourceTestError.injected }
        available = true
        id = UUID().uuidString
        return value()
    }
    func setEnabled(_ value: Bool) async throws -> APIRelayStatus {
        guard available else { throw APIRelayError.unavailable("fixture relay stopped") }
        enabled = value
        return self.value()
    }
    func replaceUnexpectedly() { id = UUID().uuidString }
    func callCounts() -> [Int] { [upgrades, restarts] }
    private func value() -> APIRelayStatus {
        APIRelayStatus(protocolVersion: 1, pid: 456, instanceId: id, host: "127.0.0.1", port: 4142,
            baseURL: "http://127.0.0.1:4142/v1", enabled: enabled, activeRequests: 0,
            activeWebSockets: 0, testMode: false, upstreamPort: 4141)
    }
}

private actor SourceGate {
    var paused = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        while !paused { await Task.yield() }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
