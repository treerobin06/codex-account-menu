import Foundation
import Darwin

public struct APIRelayStatus: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let pid: Int32
    public let instanceId: String
    public let host: String
    public let port: Int
    public let baseURL: String
    public let enabled: Bool
    public let activeRequests: Int
    public let activeWebSockets: Int
    public let testMode: Bool
    public let upstreamPort: Int
    public var observationVersion: Int? = nil
    public var observationLimit: Int? = nil
    public var recentRequests: [RelayRequestObservation]? = nil
    public var transportVersion: Int? = nil
    public var httpIdleTimeoutMs: Int? = nil
    public var upstreamConnectTimeoutMs: Int? = nil
    public var websocketHandshakeIdleTimeoutMs: Int? = nil
    public var isIdle: Bool { activeRequests == 0 && activeWebSockets == 0 }
}

public protocol APIRelayControlling: Sendable {
    func status() async throws -> APIRelayStatus?
    func ensureRunning() async throws -> APIRelayStatus
    func ensureRunningForSourceSwitch() async throws -> APIRelayStatus
    func setEnabled(_ enabled: Bool) async throws -> APIRelayStatus
}

public extension APIRelayControlling {
    func ensureRunningForSourceSwitch() async throws -> APIRelayStatus { try await ensureRunning() }
}

public enum APIRelayError: LocalizedError, Sendable {
    case unavailable(String), busy, unexpectedService, starting
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "本机 API 转发未就绪：\(detail)"
        case .busy: "API 转发仍有活动请求或 WebSocket，请等待任务结束后再切换。"
        case .unexpectedService: "本机转发端口或控制文件属于不兼容的服务，已停止切换。"
        case .starting: "本机 API 转发正在启动。"
        }
    }
}

/// A small persistent child shared by GUI and CLI through a private Unix socket.
/// It survives the menu process, and never reads OAuth files or proxy credentials.
public actor APIRelayController: APIRelayControlling {
    public let directory: URL
    public let socketURL: URL
    private let nodeURL: URL
    private let scriptURL: URL?
    private let testUpstreamPort: Int?
    private let listenPort: Int
    private var process: Process?

    public init(storage: URL) {
        self.init(directory: storage.appendingPathComponent("api-relay"),
                  nodeURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"), scriptURL: nil,
                  listenPort: 4142, testUpstreamPort: nil)
    }

    init(directory: URL, nodeURL: URL, scriptURL: URL?, listenPort: Int, testUpstreamPort: Int?) {
        self.directory = directory
        socketURL = directory.appendingPathComponent("control.sock")
        self.nodeURL = nodeURL; self.scriptURL = scriptURL
        self.listenPort = listenPort; self.testUpstreamPort = testUpstreamPort
    }

    public func status() throws -> APIRelayStatus? {
        guard let before = try socketIdentity() else { return nil }
        do { return try command("status") }
        catch let error as POSIXError where error.code == .ECONNREFUSED {
            guard try socketIdentity() == before else { throw APIRelayError.unexpectedService }
            // Read-only: a refused private socket is not a running relay.
            // Native fallback must remain available without restarting it.
            return nil
        }
    }

    public func ensureRunning() async throws -> APIRelayStatus {
        try prepareDirectory()
        if let existing = try socketIdentity() {
            do { return try command("status") }
            catch let error as POSIXError where error.code == .ECONNREFUSED {
                // A crashed child can leave its socket. Remove only a refused,
                // unchanged, private socket owned by this user; never other files.
                guard try socketIdentity() == existing else { throw APIRelayError.unexpectedService }
                guard Darwin.unlink(socketURL.path) == 0 else { throw relayPOSIX() }
            }
        }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              let script = scriptURL ?? Self.resourceURL() else {
            throw APIRelayError.unavailable("找不到现有 Node 或应用内转发程序")
        }
        let child = Process()
        child.executableURL = nodeURL
        child.arguments = [script.path, "--port", String(listenPort), "--control-socket", socketURL.path]
        if let testUpstreamPort { child.arguments! += ["--test-mode", "--test-upstream-port", String(testUpstreamPort)] }
        child.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        child.currentDirectoryURL = directory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<60 {
            if !child.isRunning { throw APIRelayError.unavailable("转发程序已退出；请检查 4142 端口是否被占用") }
            if try socketIdentity() != nil {
                do {
                    let state = try command("status")
                    guard state.pid == child.processIdentifier else { throw APIRelayError.unexpectedService }
                    return state
                } catch let error as POSIXError where error.code == .ECONNREFUSED { /* socket is binding */ }
                catch APIRelayError.starting { /* both listeners must be ready */ }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Only this newly launched, disabled child may be terminated on startup
        // failure. A reattached service and all user model tasks are untouched.
        if child.isRunning { child.terminate() }
        throw APIRelayError.unavailable("等待控制接口超时")
    }

    public func setEnabled(_ enabled: Bool) throws -> APIRelayStatus {
        try command(enabled ? "enable" : "disable")
    }

    /// Only SourceSwitchService calls this after the user-requested normal
    /// Desktop exit and writer checks. Ordinary startup/refresh always reuses
    /// a running older helper so installing the UI cannot disconnect a task.
    public func ensureRunningForSourceSwitch() async throws -> APIRelayStatus {
        guard var existing = try status() else { return try await ensureRunning() }
        guard existing.observationVersion == nil || existing.transportVersion != 2 else { return existing }
        let instance = existing.instanceId
        for _ in 0..<40 where !existing.isIdle {
            try await Task.sleep(for: .milliseconds(50))
            guard let checked = try status(), checked.instanceId == instance else {
                throw APIRelayError.unexpectedService
            }
            existing = checked
        }
        guard existing.isIdle else { throw APIRelayError.busy }
        // The control command checks idleness again atomically; no signals.
        _ = try shutdown()
        for _ in 0..<40 {
            if try socketIdentity() == nil { return try await ensureRunning() }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw APIRelayError.unavailable("旧转发尚未正常退出；保留切换恢复保护")
    }

    func shutdown() throws -> APIRelayStatus { try command("shutdown") }

    private func command(_ operation: String) throws -> APIRelayStatus {
        var parent = stat()
        guard Darwin.lstat(directory.path, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
            throw APIRelayError.unexpectedService
        }
        let original = try socketIdentity()
        guard original != nil else { throw APIRelayError.unavailable("转发程序未运行") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw relayPOSIX() }
        defer { _ = Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw APIRelayError.unavailable("控制路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else { throw relayPOSIX() }
        guard try socketIdentity() == original else { throw APIRelayError.unexpectedService }
        let id = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: ["id": id, "op": operation]) + Data([10])
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw relayPOSIX() }
                offset += count
            }
        }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while !output.contains(10) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw APIRelayError.unavailable("控制响应不完整") }
            output.append(contentsOf: buffer.prefix(count))
            guard output.count <= 65_536 else { throw APIRelayError.unexpectedService }
        }
        let line = Data(output.prefix { $0 != 10 })
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              response["event"] as? String == "control", response["id"] as? String == id,
              response["op"] as? String == operation else { throw APIRelayError.unexpectedService }
        if response["status"] as? String == "busy" { throw APIRelayError.busy }
        if response["status"] as? String == "starting" { throw APIRelayError.starting }
        guard response["ok"] as? Bool == true else { throw APIRelayError.unavailable("控制操作被拒绝") }
        let state = try JSONDecoder().decode(APIRelayStatus.self, from: line)
        guard state.protocolVersion == 1, state.pid > 0, UUID(uuidString: state.instanceId) != nil,
              state.host == "127.0.0.1", state.port == listenPort || (testUpstreamPort != nil && listenPort == 0),
              state.baseURL == "http://127.0.0.1:\(state.port)/v1",
              state.upstreamPort == (testUpstreamPort ?? 4141), state.testMode == (testUpstreamPort != nil),
              response["controlSocket"] as? String == socketURL.path else { throw APIRelayError.unexpectedService }
        return state
    }

    private struct SocketIdentity: Equatable { let device: dev_t; let inode: ino_t }
    private func socketIdentity() throws -> SocketIdentity? {
        var value = stat()
        guard Darwin.lstat(socketURL.path, &value) == 0 else {
            if errno == ENOENT { return nil }; throw relayPOSIX()
        }
        guard value.st_mode & S_IFMT == S_IFSOCK, value.st_uid == getuid(), value.st_mode & 0o077 == 0 else {
            throw APIRelayError.unexpectedService
        }
        return SocketIdentity(device: value.st_dev, inode: value.st_ino)
    }

    private func prepareDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        for item in [parent, directory] {
            var value = stat()
            if Darwin.lstat(item.path, &value) != 0 {
                guard errno == ENOENT else { throw relayPOSIX() }
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } else {
                guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid() else { throw APIRelayError.unexpectedService }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
            }
        }
    }

    static func resourceURL() -> URL? {
        let resource = "CodexAccountMenu_SwitcherCore.bundle/codex-api-relay.mjs"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(resource),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/" + resource),
            Bundle.main.bundleURL.appendingPathComponent(resource)]
        if let value = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return value }
        return Bundle.module.url(forResource: "codex-api-relay", withExtension: "mjs")
    }
}

private func relayPOSIX() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
