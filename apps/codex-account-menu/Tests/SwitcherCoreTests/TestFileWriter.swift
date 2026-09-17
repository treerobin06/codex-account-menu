import Foundation
import Darwin

/// A disposable child that only holds an existing fixture file open. Use an
/// explicit POSIX child lifecycle: Foundation's waitUntilExit can stall in
/// concurrent Swift Testing cleanup even after its child has already exited.
final class TestFileWriter: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reaped = false

    init(file: URL) { self.file = file }
    deinit { stop() }

    var processIdentifier: Int32 {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return runningLocked()
    }

    func run() throws {
        lock.lock(); defer { lock.unlock() }
        guard pid == 0 else { throw POSIXError(.EALREADY) }
        let fd = open(file.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw POSIXError(.EINVAL)
        }
        let strings: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "90"].map { text in
            text.withCString { strdup($0) }
        }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let result = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, "/bin/sleep", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { pid = 0; throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard runningLocked() else { return }
        _ = Darwin.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1)
        while runningLocked(), Date() < deadline { usleep(10_000) }
        if runningLocked() {
            _ = Darwin.kill(pid, SIGKILL) // Only this fixture's owned sleep child.
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            reaped = true
        }
    }

    private func runningLocked() -> Bool {
        guard pid > 0, !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
        return !reaped
    }
}
