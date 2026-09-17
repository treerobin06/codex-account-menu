import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(Windows)
import SwitcherPlatform
#endif

public protocol AccountStoring: Sendable {
    func loadRegistry() async throws -> AccountRegistry
    func profile(id: UUID) async throws -> AccountProfile
    func activeCredentialExists() async -> Bool
    func clearActiveCredential() async throws
    func activeCodexHome() async -> URL
    func saveCurrentCredential() async throws
    func activateTargetCredential(id: UUID) async throws
    func restoreActiveCredential(id: UUID) async throws
    func commitActiveAccountID(_ id: UUID) async throws
}

struct SourceStoreSnapshot: Sendable {
    let registry: AccountRegistry
    let registryFile: SourceFileSnapshot
    let active: SourceFileSnapshot
    let credentials: [UUID: SourceFileSnapshot]
}

/// The first version supports the complete native ChatGPT OAuth file only.
/// API-key credentials never belong to a saved ChatGPT profile.
func oauthCredentialIdentity(_ bytes: Data) throws -> AccountIdentity {
    guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          object["auth_mode"] as? String == "chatgpt",
          object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
          let tokens = object["tokens"] as? [String: Any],
          ["id_token", "access_token", "refresh_token", "account_id"].allSatisfy({
              guard let value = tokens[$0] as? String else { return false }
              return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }),
          let accountID = tokens["account_id"] as? String,
          let token = tokens["id_token"] as? String else {
        throw AccountStoreError.activeCredentialMismatch
    }
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
        throw AccountStoreError.activeCredentialMismatch
    }
    var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let decoded = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
          let email = claims["email"] as? String,
          !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AccountStoreError.activeCredentialMismatch
    }
    if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
       let claimedID = auth["chatgpt_account_id"] {
        guard claimedID as? String == accountID else { throw AccountStoreError.activeCredentialMismatch }
    }
    return AccountIdentity(accountID: accountID, email: email)
}

func validateOAuthCredential(_ bytes: Data, matching profile: AccountProfile) throws {
    let identity = try oauthCredentialIdentity(bytes)
    guard let expectedID = profile.accountID, !expectedID.isEmpty,
          let expectedEmail = profile.email, !expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          identity.accountID == expectedID, identity.matches(profile) else {
        throw AccountStoreError.activeCredentialMismatch
    }
}

public actor AccountStore: AccountStoring {
    public let baseURL: URL
    public let activeHomeURL: URL

    private let fileManager: FileManager
    private let legacyBaseURL: URL?
    private var registry: AccountRegistry?
    private var usageCache: UsageCache?

    public init(
        baseURL: URL? = nil,
        legacyBaseURL: URL? = nil,
        activeHomeURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        #if os(Windows)
        let applicationSupportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local").path)
        #else
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        #endif
        if let baseURL {
            self.baseURL = baseURL
            self.legacyBaseURL = legacyBaseURL
        } else {
            self.baseURL = applicationSupportURL.appending(
                path: "Codex Account Switcher",
                directoryHint: .isDirectory
            )
            self.legacyBaseURL = applicationSupportURL.appending(
                path: "Codex Account Switcher Lite",
                directoryHint: .isDirectory
            )
        }
        self.activeHomeURL = activeHomeURL
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private var accountsURL: URL { baseURL.appending(path: "accounts.json") }
    private var settingsURL: URL { baseURL.appending(path: "settings.json") }
    private var usageCacheURL: URL { baseURL.appending(path: "usage-cache.json") }
    private var profilesURL: URL { baseURL.appending(path: "accounts", directoryHint: .isDirectory) }

    public func loadRegistry() throws -> AccountRegistry {
        try prepareDirectories()
        // Other menu/CLI instances may register an account. Never serve an old
        // in-memory account list as the basis of a credential association.
        guard fileManager.fileExists(atPath: accountsURL.path) else {
            registry = .empty
            return .empty
        }
        let loaded = try Self.decoder.decode(AccountRegistry.self, from: readChecked(accountsURL))
        registry = loaded
        return loaded
    }

    public func reloadRegistry() throws -> AccountRegistry {
        registry = nil
        return try loadRegistry()
    }

    public func loadSettings() throws -> AppSettings {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .default }
        return try Self.decoder.decode(AppSettings.self, from: readChecked(settingsURL))
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try prepareDirectories()
        try writeJSON(settings, to: settingsURL)
    }

    public func loadUsageCache() throws -> UsageCache {
        try prepareDirectories()
        if let usageCache { return usageCache }
        guard fileManager.fileExists(atPath: usageCacheURL.path) else {
            usageCache = .empty
            return .empty
        }
        let loaded = try Self.decoder.decode(UsageCache.self, from: readChecked(usageCacheURL))
        usageCache = loaded
        return loaded
    }

    public func cacheWeeklyUsage(_ usage: WeeklyUsage, profileID: UUID, fetchedAt: Date = Date()) throws {
        let registry = try loadRegistry()
        guard registry.accounts.contains(where: { $0.id == profileID }) else { return }
        var cache = try loadUsageCache()
        let entry = UsageCacheEntry(profileID: profileID, usage: usage, fetchedAt: fetchedAt)
        if let index = cache.entries.firstIndex(where: { $0.profileID == profileID }) {
            cache.entries[index] = entry
        } else {
            cache.entries.append(entry)
        }
        try saveUsageCache(cache)
    }

    public func profile(id: UUID) throws -> AccountProfile {
        let registry = try loadRegistry()
        guard let profile = registry.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        return profile
    }

    public func profileHome(id: UUID) -> URL {
        profilesURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func activeCodexHome() -> URL { activeHomeURL }

    public func activeCredentialExists() -> Bool {
        fileManager.fileExists(atPath: activeHomeURL.appending(path: "auth.json").path)
    }

    public func createProfileDirectory(id: UUID) throws -> URL {
        try prepareDirectories()
        let directory = profileHome(id: id)
        try checkPath(directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try restrictPermissions(directory, directory: true)
        return directory
    }

    public func importCurrentProfile(_ profile: AccountProfile) throws {
        let source = activeHomeURL.appending(path: "auth.json")
        let active = try SourceFileSnapshot.read(source)
        guard let bytes = active.data else {
            throw AccountStoreError.activeCredentialMissing
        }
        try validateOAuthCredential(bytes, matching: profile)
        let registryFile = try sourceRegistrySnapshot()
        var current = try decodeSourceRegistry(registryFile)
        guard !current.accounts.contains(where: { AccountIdentity(accountID: profile.accountID, email: profile.email).matches($0) }) else {
            throw AccountStoreError.duplicateAccount
        }
        _ = try createProfileDirectory(id: profile.id)
        try active.requireUnchanged()
        _ = try SourceFileSnapshot.read(profileHome(id: profile.id).appending(path: "auth.json")).replace(with: bytes)
        current.accounts.append(profile)
        current.activeAccountID = profile.id
        try active.requireUnchanged()
        _ = try registryFile.replace(with: Self.encoder.encode(current))
        registry = current
    }

    public func addProfile(_ profile: AccountProfile) throws {
        let authURL = profileHome(id: profile.id).appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw AccountStoreError.targetCredentialMissing
        }
        try validateOAuthCredential(readChecked(authURL), matching: profile)
        try restrictPermissions(authURL, directory: false)
        var current = try loadRegistry()
        let identity = AccountIdentity(accountID: profile.accountID, email: profile.email)
        guard !current.accounts.contains(where: { identity.matches($0) }) else {
            throw AccountStoreError.duplicateAccount
        }
        current.accounts.append(profile)
        try saveRegistry(current)
    }

    public func discardUnregisteredProfile(id: UUID) throws {
        guard try !loadRegistry().accounts.contains(where: { $0.id == id }) else { return }
        let directory = profileHome(id: id)
        if fileManager.fileExists(atPath: directory.path) { try removeProfileDirectory(directory) }
    }

    public func registerActiveIdentity(_ identity: AccountIdentity) throws {
        let current = try loadRegistry()
        if let profile = current.accounts.first(where: { identity.matches($0) }) {
            let active = try SourceFileSnapshot.read(activeHomeURL.appending(path: "auth.json"))
            guard let bytes = active.data else { throw AccountStoreError.activeCredentialMissing }
            try validateOAuthCredential(bytes, matching: profile)
            guard identity.accountID == profile.accountID else { throw AccountStoreError.activeCredentialMismatch }
            let target = try SourceFileSnapshot.read(profileHome(id: profile.id).appending(path: "auth.json"))
            try active.requireUnchanged()
            _ = try target.replace(with: bytes)
            try active.requireUnchanged()
            try commitActiveAccountID(profile.id)
        } else {
            try importCurrentProfile(AccountProfile(id: UUID(), displayName: identity.suggestedDisplayName,
                email: identity.email, accountID: identity.accountID, createdAt: Date(), lastUsedAt: Date()))
        }
    }

    public func removeAccount(id: UUID) throws {
        var current = try loadRegistry()
        guard current.activeAccountID != id else {
            throw AccountStoreError.cannotRemoveActiveAccount
        }
        guard current.accounts.contains(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        var cache = try loadUsageCache()
        if cache.entries.contains(where: { $0.profileID == id }) {
            cache.entries.removeAll(where: { $0.profileID == id })
            try saveUsageCache(cache)
        }
        let original = current
        current.accounts.removeAll(where: { $0.id == id })
        try saveRegistry(current)
        do {
            try removeProfileDirectory(profileHome(id: id))
        } catch {
            let removalError = error
            do {
                try saveRegistry(original)
            } catch {
                throw NSError(domain: "CodexAccountSwitcher.AccountStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(removalError.localizedDescription) Restoring the account list also failed: \(error.localizedDescription)",
                ])
            }
            throw removalError
        }
    }

    public func saveCurrentCredential() throws {
        let current = try loadRegistry()
        guard let activeID = current.activeAccountID else {
            throw AccountStoreError.activeProfileMissing
        }
        guard let profile = current.accounts.first(where: { $0.id == activeID }) else {
            throw AccountStoreError.activeProfileMissing
        }
        let source = activeHomeURL.appending(path: "auth.json")
        let active = try SourceFileSnapshot.read(source)
        guard let bytes = active.data else {
            throw AccountStoreError.activeCredentialMissing
        }
        try validateOAuthCredential(bytes, matching: profile)
        let target = try SourceFileSnapshot.read(profileHome(id: activeID).appending(path: "auth.json"))
        try active.requireUnchanged()
        _ = try target.replace(with: bytes)
    }

    public func activateTargetCredential(id: UUID) throws {
        try installCredential(id: id)
    }

    public func clearActiveCredential() throws {
        try prepareDirectories()
        try checkPath(activeHomeURL.appending(path: "auth.json"))
        try fileManager.removeItem(at: activeHomeURL.appending(path: "auth.json"))
    }

    public func restoreActiveCredential(id: UUID) throws {
        try installCredential(id: id)
    }

    private func installCredential(id: UUID) throws {
        _ = try profile(id: id)
        let source = profileHome(id: id).appending(path: "auth.json")
        guard fileManager.fileExists(atPath: source.path) else {
            throw AccountStoreError.targetCredentialMissing
        }

        try checkPath(activeHomeURL)
        try fileManager.createDirectory(at: activeHomeURL, withIntermediateDirectories: true)
        let destination = activeHomeURL.appending(path: "auth.json")
        let bytes = try readChecked(source)
        try secureAtomicWrite(bytes, to: destination)
    }

    public func commitActiveAccountID(_ id: UUID) throws {
        var current = try loadRegistry()
        guard let index = current.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        current.activeAccountID = id
        current.accounts[index].lastUsedAt = Date()
        try saveRegistry(current)
    }

    public func renameAccount(id: UUID, displayName: String) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(domain: "CodexAccountSwitcher.AccountStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The account display name cannot be empty."])
        }
        let file = try sourceRegistrySnapshot()
        var current = try decodeSourceRegistry(file)
        guard let index = current.accounts.firstIndex(where: { $0.id == id }) else { throw AccountStoreError.profileNotFound }
        current.accounts[index].displayName = name
        _ = try file.replace(with: Self.encoder.encode(current))
        registry = current
    }

    func sourceSnapshot(targetID: UUID?) throws -> SourceStoreSnapshot {
        let registryFile = try sourceRegistrySnapshot()
        let current = try decodeSourceRegistry(registryFile)
        var credentials: [UUID: SourceFileSnapshot] = [:]
        for id in Set([current.activeAccountID, targetID].compactMap { $0 }) {
            guard current.accounts.contains(where: { $0.id == id }) else { throw AccountStoreError.profileNotFound }
            credentials[id] = try SourceFileSnapshot.read(profileHome(id: id).appending(path: "auth.json"))
        }
        let active = try SourceFileSnapshot.read(activeHomeURL.appending(path: "auth.json"))
        try registryFile.requireUnchanged()
        return SourceStoreSnapshot(registry: current, registryFile: registryFile, active: active, credentials: credentials)
    }

    func commitSourceAccount(_ id: UUID, expecting file: SourceFileSnapshot) throws -> SourceFileSnapshot {
        try prepareDirectories()
        var current = try decodeSourceRegistry(file)
        guard let index = current.accounts.firstIndex(where: { $0.id == id }) else { throw AccountStoreError.profileNotFound }
        current.activeAccountID = id
        current.accounts[index].lastUsedAt = Date()
        let installed = try file.replace(with: Self.encoder.encode(current))
        registry = current
        return installed
    }

    func sourceRegistrySnapshot() throws -> SourceFileSnapshot {
        try prepareDirectories()
        return try SourceFileSnapshot.read(accountsURL)
    }

    private func decodeSourceRegistry(_ file: SourceFileSnapshot) throws -> AccountRegistry {
        guard let data = file.data else { return .empty }
        return try Self.decoder.decode(AccountRegistry.self, from: data)
    }

    private func saveRegistry(_ value: AccountRegistry) throws {
        try writeJSON(value, to: accountsURL)
        registry = value
    }

    private func saveUsageCache(_ value: UsageCache) throws {
        try writeJSON(value, to: usageCacheURL)
        usageCache = value
    }

    private func prepareDirectories() throws {
        let defaultHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let knownDefaultStore = ["Codex Account Menu", "Codex Account Switcher", "Codex Account Switcher Lite"].contains {
            AccountStoreBinding.canonical(support.appendingPathComponent($0)) == AccountStoreBinding.canonical(baseURL)
        }
        let defaultHomeMatches = AccountStoreBinding.canonical(defaultHome) == AccountStoreBinding.canonical(activeHomeURL)
        if knownDefaultStore && !defaultHomeMatches { throw AccountStoreBindingError.differentHome }
        try checkPath(baseURL)
        try checkPath(profilesURL)
        if !fileManager.fileExists(atPath: baseURL.path),
           let legacyBaseURL,
           fileManager.fileExists(atPath: legacyBaseURL.path) {
            try checkPath(legacyBaseURL)
            try AccountStoreBinding.ensure(base: legacyBaseURL, home: activeHomeURL,
                allowExistingUnbound: knownDefaultStore && defaultHomeMatches, fileManager: fileManager)
            try fileManager.moveItem(at: legacyBaseURL, to: baseURL)
        }
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try restrictPermissions(baseURL, directory: true)
        try AccountStoreBinding.ensure(base: baseURL, home: activeHomeURL,
            allowExistingUnbound: knownDefaultStore && defaultHomeMatches, fileManager: fileManager)
        try fileManager.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try restrictPermissions(profilesURL, directory: true)
    }

    private func copyCredential(from source: URL, to destination: URL) throws {
        let bytes = try readChecked(source)
        try secureAtomicWrite(bytes, to: destination)
    }

    private func checkPath(_ path: URL) throws {
        #if os(Windows)
        let error = switcher_check_path(path.path)
        guard error == 0 else { throw windowsError(error) }
        #endif
    }

    private func readChecked(_ path: URL) throws -> Data {
        try checkPath(path)
        return try Data(contentsOf: path)
    }

    private func removeProfileDirectory(_ path: URL) throws {
        #if os(Windows)
        func checkTree(_ directory: URL) throws {
            try checkPath(directory)
            for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                try checkPath(child)
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try checkTree(child) }
            }
        }
        try checkTree(path)
        #endif
        try fileManager.removeItem(at: path)
    }

    private func secureAtomicWrite(_ bytes: Data, to destination: URL) throws {
        #if os(Windows)
        let error = bytes.withUnsafeBytes { buffer in
            switcher_atomic_write(destination.path, buffer.baseAddress, buffer.count)
        }
        guard error == 0 else { throw windowsError(error) }
        #else
        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).switcher-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }

        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard count > 0 else { throw currentPOSIXError() }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
            guard Darwin.close(descriptor) == 0 else { throw currentPOSIXError() }
        } catch {
            _ = Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        if Darwin.rename(temporary.path, destination.path) != 0 {
            let error = currentPOSIXError()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        #endif
    }

    private func restrictPermissions(_ path: URL, directory: Bool) throws {
        #if os(Windows)
        let error = switcher_restrict_path(path.path, directory ? 1 : 0)
        guard error == 0 else { throw windowsError(error) }
        #else
        try fileManager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: path.path)
        #endif
    }

    #if os(Windows)
    private func windowsError(_ code: UInt32) -> NSError {
        NSError(domain: "CodexAccountSwitcher.Windows", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Windows could not access private account storage (error \(code)).",
        ])
    }
    #else
    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #endif

    private func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let bytes = try Self.encoder.encode(value)
        try secureAtomicWrite(bytes, to: destination)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
