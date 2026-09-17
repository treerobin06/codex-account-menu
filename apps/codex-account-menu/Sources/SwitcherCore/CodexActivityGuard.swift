import Foundation
import Darwin

// Disambiguate the C function from Darwin's struct, using the SDK's inode ABI.
#if arch(x86_64)
@_silgen_name("statfs$INODE64")
#else
@_silgen_name("statfs")
#endif
private func activityStatFS(_ path: UnsafePointer<CChar>, _ value: UnsafeMutablePointer<statfs>) -> Int32

public enum CodexActivityError: LocalizedError, Sendable {
    case desktopRunning, activeWriter([Int32]), inspectionFailed, timedOut
    public var errorDescription: String? {
        switch self {
        case .desktopRunning: "Codex Desktop must be fully stopped before changing sources."
        case .activeWriter(let pids): "Codex root files have active writers: \(pids.map(String.init).joined(separator: ", "))"
        case .inspectionFailed: "Cannot safely inspect open Codex root files; no source change was permitted."
        case .timedOut: "Inspecting open Codex root files timed out; no source change was permitted."
        }
    }
}

/// Checks open writable descriptors only. Never opens SQLite or reads histories.
public struct CodexActivityGuard: Sendable {
    public let home: URL
    private let executable: URL
    private let timeout: TimeInterval

    public init(home: URL) {
        self.init(home: home, executable: URL(fileURLWithPath: "/usr/sbin/lsof"), timeout: 5)
    }

    init(home: URL, executable: URL, timeout: TimeInterval) {
        self.home = home.standardizedFileURL
        self.executable = executable
        self.timeout = timeout
    }

    public func requireQuiescent(lock: SourceSwitchLock,
                                 desktopStopped: @Sendable () async throws -> Bool) async throws {
        try Task.checkCancellation()
        try lock.requireHeld(for: home)
        guard try await desktopStopped() else { throw CodexActivityError.desktopRunning }
        try lock.requireHeld(for: home)
        var before = stat()
        guard lstat(home.path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR else {
            throw CodexActivityError.inspectionFailed
        }
        try Self.requireLocalFilesystem(home)
        var paths: [URL] = []
        for item in try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            var value = stat()
            guard lstat(item.path, &value) == 0 else { throw CodexActivityError.inspectionFailed }
            if value.st_mode & S_IFMT == S_IFREG {
                try Self.requireLocalFilesystem(item)
                paths.append(item)
            }
            else if ["auth.json", "config.toml"].contains(item.lastPathComponent)
                || (item.lastPathComponent.hasPrefix("state_") && item.lastPathComponent.contains(".sqlite")) {
                throw CodexActivityError.inspectionFailed
            }
        }
        guard paths.count <= 1024, timeout.isFinite, timeout > 0 else { throw CodexActivityError.inspectionFailed }
        paths.sort { $0.path < $1.path }
        let deadline = Date().addingTimeInterval(timeout)
        var writers: Set<Int32> = []
        for offset in stride(from: 0, to: paths.count, by: 128) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexActivityError.timedOut }
            let operation = CodexLsofOperation()
            let output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.start(executable: executable,
                        paths: Array(paths[offset..<min(offset + 128, paths.count)]),
                        timeout: remaining, continuation: continuation)
                }
            } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            writers.formUnion(try Self.writers(from: output.data, exitCode: output.exitCode))
        }
        var after = stat()
        guard lstat(home.path, &after) == 0, after.st_mode & S_IFMT == S_IFDIR,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw CodexActivityError.inspectionFailed
        }
        try lock.requireHeld(for: home)
        guard try await desktopStopped() else { throw CodexActivityError.desktopRunning }
        try Task.checkCancellation()
        if !writers.isEmpty { throw CodexActivityError.activeWriter(writers.sorted()) }
    }

    private static func requireLocalFilesystem(_ path: URL) throws {
        var filesystem = statfs()
        guard path.path.withCString({ activityStatFS($0, &filesystem) }) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw CodexActivityError.inspectionFailed
        }
    }

    static func writers(from data: Data, exitCode: Int32) throws -> Set<Int32> {
        guard [0, 1].contains(exitCode), let text = String(data: data, encoding: .utf8),
              !data.isEmpty || exitCode == 1 else { throw CodexActivityError.inspectionFailed }
        var pid: Int32?, numericDescriptor = false, hasDescriptor = false, accessRead = true
        var writers: Set<Int32> = []
        for line in text.split(separator: "\n") {
            if line.first == "p", let value = Int32(line.dropFirst()), value > 0 {
                guard accessRead else { throw CodexActivityError.inspectionFailed }
                pid = value; numericDescriptor = false; hasDescriptor = false
            } else if line.first == "f", pid != nil {
                guard accessRead else { throw CodexActivityError.inspectionFailed }
                numericDescriptor = Int(line.dropFirst()) != nil
                hasDescriptor = true; accessRead = !numericDescriptor
            } else if line.first == "a", let pid, hasDescriptor {
                if !numericDescriptor { continue } // cwd/txt/mem are not open FDs.
                guard ["ar", "aw", "au"].contains(line) else { throw CodexActivityError.inspectionFailed }
                accessRead = true
                if pid != getpid(), line == "aw" || line == "au" { writers.insert(pid) }
            } else { throw CodexActivityError.inspectionFailed }
        }
        guard accessRead else { throw CodexActivityError.inspectionFailed }
        return writers
    }
}

private struct CodexLsofOutput: Sendable { let data: Data; let exitCode: Int32 }

/// One worker owns spawning, pipe reads, signaling and waitpid. Cancellation
/// only sets a flag; there is never a second waiter racing Foundation's reaper.
private final class CodexLsofOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func start(executable: URL, paths: [URL], timeout: TimeInterval,
               continuation: CheckedContinuation<CodexLsofOutput, any Error>) {
        lock.lock()
        guard !started else {
            lock.unlock()
            continuation.resume(throwing: CodexActivityError.inspectionFailed)
            return
        }
        started = true
        lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result {
                try self.execute(executable: executable, paths: paths, deadline: deadline)
            })
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func execute(executable: URL, paths: [URL], deadline: TimeInterval) throws -> CodexLsofOutput {
        if isCancelled { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexActivityError.timedOut }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw CodexActivityError.inspectionFailed }
        let readFD = descriptors[0], writeFD = descriptors[1]
        var writeOpen = true
        defer {
            _ = Darwin.close(readFD)
            if writeOpen { _ = Darwin.close(writeFD) }
        }
        let nullFD = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw CodexActivityError.inspectionFailed }
        defer { _ = Darwin.close(nullFD) }
        guard fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw CodexActivityError.inspectionFailed
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CodexActivityError.inspectionFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CodexActivityError.inspectionFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw CodexActivityError.inspectionFailed
        }
        let arguments = [executable.path, "-nP", "-Fpa", "--"] + paths.map(\.path)
        let argvStrings = arguments.map { $0.withCString { strdup($0) } }
        let envStrings = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"].map { $0.withCString { strdup($0) } }
        defer {
            argvStrings.forEach { free($0) }
            envStrings.forEach { free($0) }
        }
        guard argvStrings.allSatisfy({ $0 != nil }), envStrings.allSatisfy({ $0 != nil }) else {
            throw CodexActivityError.inspectionFailed
        }
        var argv = argvStrings + [nil], environment = envStrings + [nil]
        var pid: pid_t = 0
        if isCancelled { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexActivityError.timedOut }
        let spawned = executable.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { args in
                environment.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&pid, executablePath, &actions, &attributes, args.baseAddress!, env.baseAddress!)
                }
            }
        }
        guard spawned == 0 else { throw CodexActivityError.inspectionFailed }
        _ = Darwin.close(writeFD)
        writeOpen = false
        // Only this worker ever waits for pid. Until it is reaped, that PID
        // cannot be recycled between a waitpid(WNOHANG) check and our signal.
        var exitStatus: Int32?
        var output = Data()
        var eof = false
        var failure: (any Error)?
        var terminatedAt: TimeInterval?
        var sentKill = false
        // A timeout bounds inspection work and starts termination. Completion
        // still requires waitpid confirmation, including after SIGKILL; a
        // pathological kernel exit delay must never release uncertain state.
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if exitStatus == nil {
                var status: Int32 = 0
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { exitStatus = status }
                else if waited == -1 && errno != EINTR {
                    // Ownership is no longer confirmed. Never signal a possibly
                    // recycled PID or accept its output as a quiescence result.
                    throw CodexActivityError.inspectionFailed
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if isCancelled { failure = CancellationError() }
                else if now >= deadline { failure = CodexActivityError.timedOut }
            }
            if failure == nil && !eof {
                // A continuously writing child must not starve cancellation or
                // waitpid. Eight reads are already the full permitted output.
                for _ in 0..<9 {
                    let count = Darwin.read(readFD, &buffer, buffer.count)
                    if count > 0 {
                        guard output.count + count <= 65_536 else {
                            failure = CodexActivityError.inspectionFailed
                            break
                        }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 { eof = true; break }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR { failure = CodexActivityError.inspectionFailed; break }
                }
            }
            if let exitStatus {
                if let failure { throw failure }
                if eof {
                    // Darwin wait status: normal exit uses the high byte; a
                    // signal or stop is never accepted as a successful probe.
                    guard exitStatus & 0x7f == 0 else { throw CodexActivityError.inspectionFailed }
                    return CodexLsofOutput(data: output, exitCode: (exitStatus >> 8) & 0xff)
                }
            } else if failure != nil {
                if terminatedAt == nil {
                    _ = Darwin.kill(pid, SIGTERM)
                    terminatedAt = now
                } else if !sentKill, now - terminatedAt! >= 0.35 {
                    _ = Darwin.kill(pid, SIGKILL)
                    sentKill = true
                }
            }
            // EOF does not imply process exit. Keep all waits nonblocking and
            // bounded so cancellation still works after a child closes stdout.
            var descriptor = pollfd(fd: eof || failure != nil ? -1 : readFD,
                                    events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 10)
            if polled < 0 && errno != EINTR { failure = CodexActivityError.inspectionFailed }
        }
    }
}
