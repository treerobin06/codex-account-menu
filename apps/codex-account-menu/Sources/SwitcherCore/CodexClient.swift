import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(AppKit)
import AppKit
#endif

public enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var intValue: Int? { doubleValue.flatMap(Int.init(exactly:)) }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

private struct RPCRemoteError: Decodable, Sendable {
    public let code: Int?
    public let message: String
}

private struct RPCEnvelope: Decodable, Sendable {
    public let id: Int?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: RPCRemoteError?
}

final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var waiters: [CheckedContinuation<Data?, any Error>] = []
    private var isFinished = false

    public init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { readable.readabilityHandler = nil; return }
            let data = readable.availableData
            guard !data.isEmpty else {
                readable.readabilityHandler = nil
                self.finish()
                return
            }
            self.consume(data)
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var parsedLines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { parsedLines.append(line) }
        }
        lock.unlock()
        for line in parsedLines {
            deliver(line)
        }
    }

    public func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func deliver(_ line: Data) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: line)
        } else {
            lines.append(line)
            lock.unlock()
        }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        if !buffer.isEmpty {
            lines.append(buffer)
            buffer.removeAll()
        }
        let pending = waiters
        waiters.removeAll()
        let deliveries = pending.map { _ in lines.isEmpty ? nil : lines.removeFirst() }
        lock.unlock()
        for (waiter, data) in zip(pending, deliveries) { waiter.resume(returning: data) }
    }
}

private final class StderrDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private let maximumBytes = 4_096

    private var isFinished = false
    private var waiters: [CheckedContinuation<String, Never>] = []

    public func finishedMessage() async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                continuation.resume(returning: message)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: message) }
    }

    public init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { readable.readabilityHandler = nil; return }
            let data = readable.availableData
            guard !data.isEmpty else {
                readable.readabilityHandler = nil
                self.finish()
                return
            }
            self.lock.lock()
            self.tail.append(data)
            if self.tail.count > self.maximumBytes {
                self.tail.removeFirst(self.tail.count - self.maximumBytes)
            }
            self.lock.unlock()
        }
    }
}

enum AccountRPCConfiguration: Sendable {
    case chatGPTAccount
    case effective

    var arguments: [String] {
        let server = ["app-server", "--listen", "stdio://"]
        switch self {
        case .chatGPTAccount:
            // This process-local path intentionally reads saved ChatGPT accounts
            // independently of the user's active API provider and credential store.
            return ["-c", "model_provider=\"openai\"", "-c", "cli_auth_credentials_store=\"file\""] + server
        case .effective:
            // Preserve every config setting, including the credential store.
            // A separate CODEX_HOME does not by itself isolate a configured keyring.
            return server
        }
    }

    static let contaminatingEnvironmentKeys = [
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_API_BASE",
        "OPENROUTER_API_KEY", "SJTU_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN",
    ]

    static func environment(_ inherited: [String: String], profileHome: URL) -> [String: String] {
        var environment = AccountProxyEnvironment.applying(to: inherited)
        for key in contaminatingEnvironmentKeys { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = profileHome.path
        return environment
    }
}

private actor JSONRPCSession {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let pump: LinePump
    private let stderrDrain: StderrDrain
    private let decoder = JSONDecoder()
    private var didTimeout = false
    private var stopping = false
    private var pendingNotifications: [RPCEnvelope] = []

    public init(executableURL: URL, profileHome: URL, environment inheritedEnvironment: [String: String],
                configuration: AccountRPCConfiguration = .chatGPTAccount) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = configuration.arguments
        process.environment = AccountRPCConfiguration.environment(inheritedEnvironment, profileHome: profileHome)
        process.currentDirectoryURL = profileHome
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let pump = LinePump(handle: outputPipe.fileHandleForReading)
        let stderrDrain = StderrDrain(handle: errorPipe.fileHandleForReading)
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        self.pump = pump
        self.stderrDrain = stderrDrain

        do {
            try process.run()
        } catch {
            throw CodexClientError.processLaunchFailed(error.localizedDescription)
        }
    }

    public func initialize(timeout: Duration, clientVersion: String) async throws {
        try send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "codex_account_menu",
                    "title": "Codex Account Menu",
                    "version": clientVersion,
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ])
        _ = try await response(id: 0, timeout: timeout)
        try send(["method": "initialized", "params": [:]])
    }

    public func request(
        method: String,
        id: Int,
        params: [String: Any] = [:],
        timeout: Duration
    ) async throws -> JSONValue {
        try send(["method": method, "id": id, "params": params])
        let envelope = try await response(id: id, timeout: timeout)
        guard let result = envelope.result else { throw CodexClientError.malformedResponse }
        return result
    }

    public func notification(method: String, timeout: Duration) async throws -> JSONValue {
        let envelope = try await receive(
            where: { $0.method == method && $0.id == nil },
            timeout: timeout
        )
        return envelope.params ?? .object([:])
    }

    public func stop() async {
        if !stopping {
            stopping = true
            try? input.close()
            if process.isRunning { process.terminate() }
        }
        pump.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline { await Self.cleanupPause() }
        #if canImport(Darwin)
        if process.isRunning {
            // Only this session's own helper can be signalled here.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        #endif
        while process.isRunning { await Self.cleanupPause() }
        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        stderrDrain.finish()
    }

    private static func cleanupPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }

    private func response(id: Int, timeout: Duration) async throws -> RPCEnvelope {
        try await receive(where: { $0.id == id }, timeout: timeout)
    }

    private func receive(
        where predicate: @escaping @Sendable (RPCEnvelope) -> Bool,
        timeout: Duration
    ) async throws -> RPCEnvelope {
        if let index = pendingNotifications.firstIndex(where: predicate) {
            return pendingNotifications.remove(at: index)
        }
        didTimeout = false
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.triggerTimeout()
            } catch {
                // Cancellation means a response arrived before the deadline.
            }
        }
        defer { timeoutTask.cancel() }

        while let line = try await pump.next() {
            let message: RPCEnvelope
            do {
                message = try decoder.decode(RPCEnvelope.self, from: line)
            } catch {
                throw CodexClientError.malformedResponse
            }
            if predicate(message) {
                if let error = message.error {
                    throw CodexClientError.remoteError(code: error.code, message: error.message)
                }
                return message
            }
            // Login completion can arrive before the login/start response.
            if message.method == "account/login/completed", message.id == nil {
                pendingNotifications.append(message)
                if pendingNotifications.count > 16 { pendingNotifications.removeFirst() }
            }
        }
        if didTimeout { throw CodexClientError.timeout }
        let details = await stderrDrain.finishedMessage()
        if didTimeout { throw CodexClientError.timeout }
        if !details.isEmpty { throw CodexClientError.connectionClosedWithDetails(details) }
        throw CodexClientError.connectionClosed
    }

    private func triggerTimeout() {
        didTimeout = true
        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        pump.finish()
        stderrDrain.finish()
    }

    private func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexClientError.malformedResponse
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }
}

public struct CodexExecutableLocator: Sendable {
    public let explicitURL: URL?

    public init(explicitURL: URL? = nil) {
        self.explicitURL = explicitURL
    }

    public func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let explicitURL, isExecutable(explicitURL.path) {
            return explicitURL
        }
        let command = environment["CODEX_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = command.flatMap { $0.isEmpty ? nil : $0 } ?? "codex"
        #if os(Windows)
        if executable.contains("/") || executable.contains("\\") {
            guard URL(fileURLWithPath: executable).path == executable.replacingOccurrences(of: "\\", with: "/")
                    || (executable.count > 2 && executable[executable.index(after: executable.startIndex)] == ":") else {
                throw CodexClientError.executableNotFound
            }
            guard isExecutable(executable) else { throw CodexClientError.executableNotFound }
            return URL(fileURLWithPath: executable)
        }
        for directory in (environment["Path"] ?? environment["PATH"] ?? "").split(separator: ";") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(
                executable.lowercased().hasSuffix(".exe") ? executable : executable + ".exe")
            if isExecutable(candidate.path) { return candidate }
        }
        if let local = environment["LOCALAPPDATA"] {
            let bin = URL(fileURLWithPath: local).appendingPathComponent("OpenAI/Codex/bin")
            let versions = (try? FileManager.default.contentsOfDirectory(at: bin,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for version in versions.sorted(by: {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }) {
                let candidate = version.appendingPathComponent("codex.exe")
                if isExecutable(candidate.path) { return candidate }
            }
        }
        #else
        if executable.contains("/") {
            guard executable.hasPrefix("/"), isExecutable(executable) else {
                throw CodexClientError.processLaunchFailed("CODEX_CLI_PATH is not executable: \(executable)")
            }
            return URL(fileURLWithPath: executable)
        }
        if let path = environment["PATH"]?
            .split(separator: ":")
            .filter({ $0.hasPrefix("/") })
            .map({ String($0) + "/" + executable })
            .first(where: isExecutable)
        {
            return URL(fileURLWithPath: path)
        }
        #endif
        throw CodexClientError.executableNotFound
    }

    public func launchConfiguration() throws -> (executable: URL, environment: [String: String]) {
        var environment = ProcessInfo.processInfo.environment
        #if !os(Windows)
        if explicitURL == nil {
            // GUI apps do not inherit the terminal's login PATH. Read the same shell settings
            // Desktop uses, and pass that PATH to npm's `#!/usr/bin/env node` launcher as well.
            let shell = Process()
            let output = Pipe()
            shell.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
            shell.arguments = ["-l", "-c", "printf '\\0%s\\0%s\\0' \"$PATH\" \"${CODEX_CLI_PATH:-codex}\""]
            shell.standardOutput = output
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            let fields = String(decoding: bytes, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            guard shell.terminationStatus == 0, fields.count >= 4 else {
                throw CodexClientError.processLaunchFailed("Could not read the login shell's Codex path.")
            }
            environment["PATH"] = String(fields[fields.count - 3])
            environment["CODEX_CLI_PATH"] = String(fields[fields.count - 2])
        }
        #endif
        return (try locate(environment: environment), environment)
    }

    private func isExecutable(_ path: String) -> Bool {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        return path.lowercased().hasSuffix(".exe")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        #else
        FileManager.default.isExecutableFile(atPath: path)
        #endif
    }
}

public protocol AccountClient: CodexIdentityReading {
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage
    func login(profileHome: URL) async throws -> AccountIdentity
    func verifyIdentity(profileHome: URL) async throws -> AccountIdentity
    func readAccountUsage(profileHome: URL) async throws -> AccountUsage
    func readEffectiveAuthStatus(profileHome: URL) async throws -> EffectiveAuthStatus
}

public struct AccountUsage: Sendable, Equatable {
    public let identity: AccountIdentity
    public let usage: WeeklyUsage
    public init(identity: AccountIdentity, usage: WeeklyUsage) { self.identity = identity; self.usage = usage }
}

public extension AccountClient {
    func readEffectiveAuthStatus(profileHome: URL) async throws -> EffectiveAuthStatus {
        throw EffectiveAuthStatusError.notSupported
    }
    func verifyIdentity(profileHome: URL) async throws -> AccountIdentity {
        try await readIdentity(profileHome: profileHome)
    }
    func readAccountUsage(profileHome: URL) async throws -> AccountUsage {
        let identity = try await readIdentity(profileHome: profileHome)
        let usage = try await readWeeklyUsage(profileHome: profileHome)
        return AccountUsage(identity: identity, usage: usage)
    }
}

public struct CodexClient: AccountClient {
    public let locator: CodexExecutableLocator
    public let requestTimeout: Duration
    public let clientVersion: String
    private let openBrowser: @Sendable (URL) async throws -> Void

    public init(locator: CodexExecutableLocator = .init(), requestTimeout: Duration = .seconds(20),
                clientVersion: String = "0.1.12",
                openBrowser: @escaping @Sendable (URL) async throws -> Void = CodexClient.defaultOpenBrowser) {
        self.locator = locator
        self.requestTimeout = requestTimeout
        self.clientVersion = clientVersion
        self.openBrowser = openBrowser
    }

    public static func defaultOpenBrowser(_ url: URL) async throws {
        #if canImport(AppKit)
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw CodexClientError.loginFailed("The sign-in page could not be opened.")
        }
        #else
        throw CodexClientError.loginFailed("A native browser adapter is required.")
        #endif
    }

    public func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        let result = try await withSession(profileHome: profileHome) { session in
            try await session.request(
                method: "account/read",
                id: 1,
                params: ["refreshToken": false],
                timeout: requestTimeout
            )
        }
        return try enrichedIdentity(parseIdentity(result), profileHome: profileHome)
    }

    public func verifyIdentity(profileHome: URL) async throws -> AccountIdentity {
        let result = try await withSession(profileHome: profileHome) { session in
            // A successful native quota read validates upstream authorization;
            // account/read alone can describe an expired locally cached login.
            let before = try enrichedIdentity(parseIdentity(await session.request(method: "account/read", id: 1,
                params: ["refreshToken": false], timeout: requestTimeout)), profileHome: profileHome)
            let quota = try await session.request(method: "account/rateLimits/read", id: 2,
                params: ["excludeResetCreditDetails": true], timeout: requestTimeout)
            let value = try await session.request(method: "account/read", id: 3,
                params: ["refreshToken": false], timeout: requestTimeout)
            let identity = try enrichedIdentity(parseIdentity(value), profileHome: profileHome)
            try requireConsistentIdentity(before, identity)
            _ = try identityBoundToQuota(before, quota: quota)
            return try identityBoundToQuota(identity, quota: quota)
        }
        return result
    }

    /// Reads metadata using the home's configured provider and credential store.
    /// The runtime may use a configured keyring; this method never forces file
    /// storage to make an effective-configuration probe appear authenticated.
    /// This is an auth-state observation, not an upstream model request.
    public func readEffectiveAuthStatus(profileHome: URL) async throws -> EffectiveAuthStatus {
        let expected = try await ProviderConfiguration(codexHome: profileHome).readRoute()
        return try await withSession(profileHome: profileHome, configuration: .effective) { session in
            // app-server can initialize with defaults after a configuration error.
            // Its auth metadata alone may then look valid for the wrong runtime.
            let configuration = try await session.request(method: "config/read", id: 1,
                params: ["includeLayers": false], timeout: requestTimeout)
            guard let resolved = configuration["config"]?.objectValue else {
                throw CodexClientError.malformedResponse
            }
            if expected.isManaged {
                // Authentication can succeed even if a profile or environment
                // selected another endpoint. Validate the resolved route too.
                guard resolved["model_provider"]?.stringValue == expected.physicalProvider else {
                    throw SourceFileError.invalidConfiguration("effective model_provider differs from the selected route")
                }
                let actualBase = resolved["openai_base_url"]?.stringValue
                let requiredBase = expected.apiEnabled ? ProviderRouteState.relayBaseURL : nil
                guard actualBase == requiredBase else {
                    throw SourceFileError.invalidConfiguration("effective openai_base_url differs from the selected route")
                }
                if expected.physicalProvider == "copilot" {
                    let actual = resolved["model_providers"]?["copilot"]
                    guard actual?["base_url"]?.stringValue == ProviderRouteState.relayBaseURL,
                          actual?["requires_openai_auth"]?.boolValue == false,
                          actual?["experimental_bearer_token"]?.stringValue == "local" else {
                        throw SourceFileError.invalidConfiguration("effective Copilot relay configuration differs from the selected route")
                    }
                }
            }
            let status = try await session.request(method: "getAuthStatus", id: 2,
                params: ["includeToken": false], timeout: requestTimeout)
            guard let requiresAuth = status["requiresOpenaiAuth"]?.boolValue else {
                throw CodexClientError.malformedResponse
            }
            let method: String?
            switch status["authMethod"] {
            case let .string(value): method = value.isEmpty ? nil : value
            case .null, nil: method = nil
            default: throw CodexClientError.malformedResponse
            }
            let account = try await session.request(method: "account/read", id: 3,
                params: ["refreshToken": false], timeout: requestTimeout)
            guard let accountRequiresAuth = account["requiresOpenaiAuth"]?.boolValue else {
                throw CodexClientError.malformedResponse
            }
            guard accountRequiresAuth == requiresAuth else {
                throw EffectiveAuthStatusError.inconsistentState
            }
            var identity: AccountIdentity?
            switch account["account"] {
            case .null, nil:
                identity = nil
            case let .object(value):
                if value["type"]?.stringValue == "chatgpt" || value["type"]?.stringValue == "chatgptAuthTokens" {
                    identity = try parseIdentity(account)
                } else {
                    identity = nil
                }
            default:
                throw CodexClientError.malformedResponse
            }
            if requiresAuth, method == "chatgpt", let current = identity, current.accountID == nil {
                // account/read can omit the workspace ID. Only an authoritative
                // response from this same runtime may fill it; never infer it
                // from auth.json when validating effective configuration.
                let quota = try await session.request(method: "account/rateLimits/read", id: 4,
                    params: ["excludeResetCreditDetails": true], timeout: requestTimeout)
                if let accountID = quota["accountId"]?.stringValue, !accountID.isEmpty {
                    let latest = try await session.request(method: "account/read", id: 5,
                        params: ["refreshToken": false], timeout: requestTimeout)
                    guard latest["requiresOpenaiAuth"]?.boolValue == requiresAuth else {
                        throw EffectiveAuthStatusError.inconsistentState
                    }
                    let latestIdentity = try parseIdentity(latest)
                    try requireConsistentIdentity(current, latestIdentity)
                    identity = try identityBoundToQuota(latestIdentity, quota: quota)
                }
            }
            // Deliberately do not read or retain a returned authToken field.
            return EffectiveAuthStatus(authMethod: method, requiresOpenaiAuth: requiresAuth, identity: identity)
        }
    }

    private func enrichedIdentity(_ identity: AccountIdentity, profileHome: URL) throws -> AccountIdentity {
        // Some desktop versions omit accountId from account/read. The native
        // file supplies the workspace discriminator, while the RPC verifies the
        // active login. Never fall back to a different email from storage.
        if identity.accountID == nil,
           let data = try? Data(contentsOf: profileHome.appending(path: "auth.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = object["tokens"] as? [String: Any],
           let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
           let jwt = tokens["id_token"] as? String,
           let payload = jwt.split(separator: ".").dropFirst().first {
            var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            if let bytes = Data(base64Encoded: base64),
               let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let storedEmail = claims["email"] as? String,
               let email = identity.email, email.caseInsensitiveCompare(storedEmail) == .orderedSame {
                return AccountIdentity(accountID: accountID, email: email)
            }
        }
        return identity
    }

    public func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage {
        let result = try await withSession(profileHome: profileHome) { session in
            try await session.request(
                method: "account/rateLimits/read",
                id: 1,
                timeout: requestTimeout
            )
        }
        return try WeeklyUsageNormalizer.normalize(parseWindows(result))
    }

    public func readAccountUsage(profileHome: URL) async throws -> AccountUsage {
        try await withSession(profileHome: profileHome) { session in
            // The quota has an account/workspace ID but no user email. Observe
            // identity on both sides so a same-workspace login change is rejected.
            let before = try enrichedIdentity(parseIdentity(await session.request(method: "account/read", id: 1,
                params: ["refreshToken": false], timeout: requestTimeout)), profileHome: profileHome)
            let limits = try await session.request(method: "account/rateLimits/read", id: 2,
                params: ["excludeResetCreditDetails": true], timeout: requestTimeout)
            let account = try await session.request(method: "account/read", id: 3,
                params: ["refreshToken": false], timeout: requestTimeout)
            let identity = try enrichedIdentity(parseIdentity(account), profileHome: profileHome)
            try requireConsistentIdentity(before, identity)
            _ = try identityBoundToQuota(before, quota: limits)
            return AccountUsage(identity: try identityBoundToQuota(identity, quota: limits),
                usage: try WeeklyUsageNormalizer.normalize(parseWindows(limits)))
        }
    }

    private func requireConsistentIdentity(_ before: AccountIdentity, _ after: AccountIdentity) throws {
        if let accountID = before.accountID, let latest = after.accountID, accountID != latest {
            throw AccountStoreError.activeCredentialMismatch
        }
        if let email = before.email {
            guard let latest = after.email, email.caseInsensitiveCompare(latest) == .orderedSame else {
                throw AccountStoreError.activeCredentialMismatch
            }
        }
    }

    private func identityBoundToQuota(_ identity: AccountIdentity, quota: JSONValue) throws -> AccountIdentity {
        guard let accountID = quota["accountId"]?.stringValue, !accountID.isEmpty else {
            throw CodexClientError.identityUnavailable
        }
        if let reportedID = identity.accountID, reportedID != accountID {
            throw AccountStoreError.activeCredentialMismatch
        }
        return AccountIdentity(accountID: accountID, email: identity.email)
    }

    public func login(profileHome: URL) async throws -> AccountIdentity {
        let launch = try locator.launchConfiguration()
        let session = try JSONRPCSession(executableURL: launch.executable, profileHome: profileHome, environment: launch.environment)
        return try await withTaskCancellationHandler {
            do {
                try await session.initialize(timeout: requestTimeout, clientVersion: clientVersion)
                let start = try await session.request(
                    method: "account/login/start",
                    id: 1,
                    params: [
                        "type": "chatgpt",
                        "useHostedLoginSuccessPage": true,
                        "appBrand": "codex",
                    ],
                    timeout: requestTimeout
                )
                guard let authURLString = start["authUrl"]?.stringValue,
                      let authURL = URL(string: authURLString)
                else {
                    throw CodexClientError.malformedResponse
                }
                try await openBrowser(authURL)

                let completion = try await session.notification(
                    method: "account/login/completed",
                    timeout: .seconds(600)
                )
                guard completion["success"]?.boolValue == true else {
                    throw CodexClientError.loginFailed(
                        completion["error"]?.stringValue ?? "The sign-in did not complete."
                    )
                }
                let identityValue = try await session.request(
                    method: "account/read",
                    id: 2,
                    params: ["refreshToken": false],
                    timeout: requestTimeout
                )
                let identity = try enrichedIdentity(parseIdentity(identityValue), profileHome: profileHome)
                await session.stop()
                return identity
            } catch {
                await session.stop()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await session.stop() }
        }
    }

    private func withSession<T: Sendable>(
        profileHome: URL,
        configuration: AccountRPCConfiguration = .chatGPTAccount,
        operation: (JSONRPCSession) async throws -> T
    ) async throws -> T {
        let launch = try locator.launchConfiguration()
        let session = try JSONRPCSession(executableURL: launch.executable, profileHome: profileHome,
            environment: launch.environment, configuration: configuration)
        do {
            try await session.initialize(timeout: requestTimeout, clientVersion: clientVersion)
            let result = try await operation(session)
            await session.stop()
            return result
        } catch {
            await session.stop()
            throw error
        }
    }

    private func parseIdentity(_ value: JSONValue) throws -> AccountIdentity {
        guard let account = value["account"]?.objectValue else {
            throw CodexClientError.identityUnavailable
        }
        let accountID = account["accountId"]?.stringValue
            ?? account["accountID"]?.stringValue
            ?? account["chatgptAccountId"]?.stringValue
            ?? account["id"]?.stringValue
        guard let email = account["email"]?.stringValue,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexClientError.identityUnavailable
        }
        return AccountIdentity(accountID: accountID, email: email)
    }

    private func parseWindows(_ value: JSONValue) -> [RateLimitWindow] {
        guard let bucket = value["rateLimitsByLimitId"]?["codex"] ?? value["rateLimits"] else {
            return []
        }
        return [bucket["primary"], bucket["secondary"]].compactMap(parseWindow)
    }

    private func parseWindow(_ value: JSONValue?) -> RateLimitWindow? {
        guard let value,
              let used = value["usedPercent"]?.doubleValue,
              let duration = value["windowDurationMins"]?.intValue
                ?? value["durationMinutes"]?.intValue,
              let reset = value["resetsAt"]?.doubleValue
        else {
            return nil
        }
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: reset
        )
    }
}
