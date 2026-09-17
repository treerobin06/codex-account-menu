import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotSnapshot: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let login: String
    public let plan: String
    public let remainingPercent: Double?
    public let resetsAt: Date?
    public let tokenBasedBilling: Bool
    public let overagePermitted: Bool
    public let modelsAvailable: Int?

    public init(
        observedAt: Date, login: String, plan: String,
        remainingPercent: Double?, resetsAt: Date?,
        tokenBasedBilling: Bool, overagePermitted: Bool,
        modelsAvailable: Int? = nil
    ) {
        self.observedAt = observedAt
        self.login = login
        self.plan = plan
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.tokenBasedBilling = tokenBasedBilling
        self.overagePermitted = overagePermitted
        self.modelsAvailable = modelsAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case observedAt, login, plan, remainingPercent, resetsAt
        case tokenBasedBilling, overagePermitted, modelsAvailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys, required: Bool = false) throws -> Date? {
            guard let text = try container.decodeIfPresent(String.self, forKey: key) else {
                if required {
                    throw DecodingError.valueNotFound(Date.self, .init(codingPath: decoder.codingPath, debugDescription: "Missing timestamp"))
                }
                return nil
            }
            guard let date = Self.parseTimestamp(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid ISO8601 timestamp")
            }
            return date
        }
        observedAt = try date(.observedAt, required: true)!
        login = try container.decode(String.self, forKey: .login)
        plan = try container.decode(String.self, forKey: .plan)
        remainingPercent = try container.decodeIfPresent(Double.self, forKey: .remainingPercent)
        resetsAt = try date(.resetsAt)
        tokenBasedBilling = try container.decode(Bool.self, forKey: .tokenBasedBilling)
        overagePermitted = try container.decode(Bool.self, forKey: .overagePermitted)
        modelsAvailable = try container.decodeIfPresent(Int.self, forKey: .modelsAvailable)
        guard !login.isEmpty, !plan.isEmpty,
              remainingPercent?.isFinite != false,
              modelsAvailable.map({ $0 >= 0 }) != false else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid status value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.timestamp(observedAt), forKey: .observedAt)
        try container.encode(login, forKey: .login)
        try container.encode(plan, forKey: .plan)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(resetsAt.map(Self.timestamp), forKey: .resetsAt)
        try container.encode(tokenBasedBilling, forKey: .tokenBasedBilling)
        try container.encode(overagePermitted, forKey: .overagePermitted)
        try container.encode(modelsAvailable, forKey: .modelsAvailable)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

public enum CopilotUsageError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration, collectorUnavailable, connectionFailed, timedOut
    case credentialsUnavailable, authenticationFailed, rateLimited, upstreamUnavailable, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Copilot 额度读取配置无效"
        case .collectorUnavailable: "应用缺少 Copilot 额度读取资源"
        case .connectionFailed: "无法通过 SSH 读取远端 Copilot 额度"
        case .timedOut: "Copilot 额度读取超时"
        case .credentialsUnavailable: "远端 Copilot 凭据不可用"
        case .authenticationFailed: "Copilot 额度鉴权失败"
        case .rateLimited: "Copilot 额度接口暂时限流"
        case .upstreamUnavailable: "Copilot 额度接口暂时不可用"
        case .invalidResponse: "Copilot 额度数据无效"
        }
    }
}

public struct CopilotUsageService: Sendable {
    private let sshHost: String
    private let timeout: TimeInterval

    public init(sshHost: String = "copilot-server", timeout: TimeInterval = 25) {
        self.sshHost = sshHost
        self.timeout = timeout
    }

    public func fetch() async throws -> CopilotSnapshot {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 300,
              !sshHost.isEmpty, sshHost.count <= 255, !sshHost.hasPrefix("-"),
              sshHost.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:@[]").contains($0)
              }) else { throw CopilotUsageError.invalidConfiguration }
        guard let source = Self.collectorURL else { throw CopilotUsageError.collectorUnavailable }
        async let models = Self.readLocalModels(timeout: min(timeout, 2))
        let operation = CopilotSSHOperation()
        let output: CopilotSSHOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(host: sshHost, source: source, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
        let snapshot = try Self.decodeOutput(output.data, exitCode: output.exitCode)
        return CopilotSnapshot(
            observedAt: snapshot.observedAt, login: snapshot.login, plan: snapshot.plan,
            remainingPercent: snapshot.remainingPercent, resetsAt: snapshot.resetsAt,
            tokenBasedBilling: snapshot.tokenBasedBilling, overagePermitted: snapshot.overagePermitted,
            modelsAvailable: await models
        )
    }

    static var collectorURL: URL? {
        // SwiftPM's generated accessor assumes a resource bundle beside an
        // executable. Signed macOS apps must instead keep data in Resources;
        // the diagnostic CLI is inside Contents/Helpers.
        let resource = "CodexAccountMenu_SwitcherCore.bundle/copilot-status.py"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(resource),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/" + resource),
            Bundle.main.bundleURL.appendingPathComponent(resource),
        ].compactMap { $0 }
        if let found = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) { return found }
        return Bundle.module.url(forResource: "copilot-status", withExtension: "py")
    }

    static func decodeOutput(_ data: Data, exitCode: Int32) throws -> CopilotSnapshot {
        struct Failure: Decodable {
            struct Detail: Decodable { let code: String }
            let error: Detail
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            switch failure.error.code {
            case "credentials_unavailable", "unsupported_account_host": throw CopilotUsageError.credentialsUnavailable
            case "authentication_failed", "identity_mismatch": throw CopilotUsageError.authenticationFailed
            case "rate_limited": throw CopilotUsageError.rateLimited
            case "invalid_upstream_response": throw CopilotUsageError.invalidResponse
            default: throw CopilotUsageError.upstreamUnavailable
            }
        }
        guard exitCode == 0 else { throw CopilotUsageError.connectionFailed }
        do {
            return try JSONDecoder().decode(CopilotSnapshot.self, from: data)
        } catch {
            // Decoder errors and SSH stderr must never surface raw response text.
            throw CopilotUsageError.invalidResponse
        }
    }

    static func modelCount(from data: Data) -> Int? {
        struct Health: Decodable {
            struct Models: Decodable { let count: Int? }
            let modelsAvailable: Int?
            let modelCount: Int?
            let models: Models?
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: data),
              let count = health.modelsAvailable ?? health.modelCount ?? health.models?.count,
              count >= 0 else { return nil }
        return count
    }

    private static func readLocalModels(timeout: TimeInterval) async -> Int? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:4141/readyz")!
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536 else { return nil }
            return modelCount(from: data)
        } catch {
            return nil
        }
    }
}

private struct CopilotSSHOutput: Sendable {
    let data: Data
    let exitCode: Int32
}

/// The lock owns completion and launch state; pipe reads occur on one worker.
/// Cancellation/timeout terminates only the SSH client created by this object.
private final class CopilotSSHOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private var input: FileHandle?
    private var continuation: CheckedContinuation<CopilotSSHOutput, any Error>?
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    func start(
        host: String, source: URL, timeout: TimeInterval,
        continuation: CheckedContinuation<CopilotSSHOutput, any Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "--", host, "sudo -n python3 -",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CopilotUsageError.timedOut), terminate: true)
        }
        timeoutWork = deadline
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        DispatchQueue.global(qos: .utility).async { self.execute(source: source) }
    }

    func cancel() { finish(.failure(CancellationError()), terminate: true) }

    private func execute(source: URL) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        do {
            input = try FileHandle(forReadingFrom: source)
            process.standardInput = input
            try process.run()
        } catch {
            try? input?.close()
            lock.unlock()
            finish(.failure(CopilotUsageError.connectionFailed), terminate: false)
            return
        }
        lock.unlock()
        defer {
            try? input?.close()
            try? output.fileHandleForReading.close()
        }
        do {
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8_192), !chunk.isEmpty {
                guard data.count + chunk.count <= 65_536 else {
                    finish(.failure(CopilotUsageError.invalidResponse), terminate: true)
                    return
                }
                data.append(chunk)
            }
            process.waitUntilExit()
            finish(.success(CopilotSSHOutput(data: data, exitCode: process.terminationStatus)), terminate: false)
        } catch {
            finish(.failure(CopilotUsageError.connectionFailed), terminate: true)
        }
    }

    private func finish(_ result: Result<CopilotSSHOutput, any Error>, terminate: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        timeoutWork?.cancel()
        let callback = continuation
        continuation = nil
        if terminate, process.isRunning { process.terminate() }
        lock.unlock()
        callback?.resume(with: result)
    }
}
