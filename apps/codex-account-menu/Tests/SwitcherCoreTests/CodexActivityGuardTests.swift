import Foundation
import Testing
import Darwin
@testable import SwitcherCore

@Suite(.serialized)
struct CodexActivityGuardTests {
    @Test(arguments: ["auth.json", "config.toml", "state_99.sqlite", "state_99.sqlite-wal",
                      "state_99.sqlite-shm", "logs_2.sqlite", "queue_1.sqlite", "future-runtime.lock"])
    func rootWritersAreRejectedWithoutReadingContentsOrTerminatingThem(filename: String) async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let file = fixture.home.appending(path: filename)
        let bytes = Data("this is deliberately not SQLite".utf8)
        try bytes.write(to: file)
        let writer = TestFileWriter(file: file)
        try writer.run()
        defer { writer.stop() }
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        do {
            try await CodexActivityGuard(home: fixture.home).requireQuiescent(lock: lock, desktopStopped: { true })
            Issue.record("A root writer must block a source change, including a runtime holding only logs or queues")
        } catch CodexActivityError.activeWriter(let pids) { #expect(pids.contains(writer.processIdentifier)) }
        #expect(writer.isRunning)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func immediateExitRepeatedlyCompletesWithoutASecondWaiter() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let start = Date()
        for _ in 0..<30 {
            try await CodexActivityGuard(home: fixture.home, executable: script, timeout: 1)
                .requireQuiescent(lock: lock, desktopStopped: { true })
        }
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func repeatedCancellationRacesWithImmediateExitAndAlwaysCompletes() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        let pidFile = fixture.root.appending(path: "immediate-pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let start = Date()
        for iteration in 0..<30 {
            try? FileManager.default.removeItem(at: pidFile)
            let guard_ = CodexActivityGuard(home: fixture.home, executable: script, timeout: 1)
            let task = Task { try await guard_.requireQuiescent(lock: lock, desktopStopped: { true }) }
            if !iteration.isMultiple(of: 2) {
                // Half the cancellations must race a genuinely spawned,
                // immediately exiting child rather than all winning pre-start.
                let deadline = Date().addingTimeInterval(0.8)
                while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(FileManager.default.fileExists(atPath: pidFile.path))
            }
            task.cancel()
            do { try await task.value }
            catch is CancellationError { /* Either terminal result may win the race. */ }
            catch { Issue.record("Unexpected cancellation result: \(error)") }
            if FileManager.default.fileExists(atPath: pidFile.path) {
                let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
            }
        }
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func stdoutClosingBeforeProcessExitStillHonorsTheTimeoutAndReaps() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        let pidFile = fixture.root.appending(path: "owned-pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec 1>&-\ntrap '' TERM\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let start = Date()
        await #expect(throws: CodexActivityError.self) {
            try await CodexActivityGuard(home: fixture.home, executable: script, timeout: 0.3)
                .requireQuiescent(lock: lock, desktopStopped: { true })
        }
        #expect(Date().timeIntervalSince(start) < 3)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func realLsofReturnsPromptlyForAnIsolatedEmptyHome() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let start = Date()
        for _ in 0..<3 {
            try await CodexActivityGuard(home: fixture.home)
                .requireQuiescent(lock: lock, desktopStopped: { true })
        }
        #expect(Date().timeIntervalSince(start) < 12)
    }

    @Test func descriptorParsingRejectsIncompleteOrUnknownInspectionOutput() throws {
        let text = "p999999\nf3\nar\nf4\nau\np\(getpid())\nf5\naw\n"
        #expect(try CodexActivityGuard.writers(from: Data(text.utf8), exitCode: 0) == [999999])
        #expect(try CodexActivityGuard.writers(from: Data(), exitCode: 1).isEmpty)
        for invalid in ["p99\nf3\n", "p99\nau\n", "p99\nf3\na?\n", "lsof: inspection warning\n"] {
            #expect(throws: CodexActivityError.self) {
                try CodexActivityGuard.writers(from: Data(invalid.utf8), exitCode: 0)
            }
        }
    }

    @Test(arguments: ["timeout", "overflow", "ignore-term"])
    func helperFailuresAreBoundedAndFailClosed(mode: String) async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        let pidFile = fixture.root.appending(path: "owned-pid")
        let body = mode == "overflow" ? "exec /usr/bin/yes invalid-output" : "exec /bin/sleep 30"
        let ignoredSignal = mode == "ignore-term" ? "trap '' TERM\n" : ""
        try Data("#!/bin/sh\n\(ignoredSignal)echo $$ > '\(pidFile.path)'\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        // A timeout includes launch scheduling. That case may correctly return
        // before the shell writes its PID; the other cases verify a running
        // child is reaped, including one that ignores normal termination.
        let budget: TimeInterval = mode == "timeout" ? 0.2 : 5
        let guard_ = CodexActivityGuard(home: fixture.home, executable: script, timeout: budget)
        let start = Date()
        await #expect(throws: CodexActivityError.self) {
            try await guard_.requireQuiescent(lock: lock, desktopStopped: { true })
        }
        #expect(Date().timeIntervalSince(start) < budget + 3)
        if mode != "timeout" || FileManager.default.fileExists(atPath: pidFile.path) {
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        }
    }

    @Test func unrelatedMountWarningsDoNotCorruptLocalDescriptorOutput() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        try Data("#!/bin/sh\nprintf 'lsof: unrelated mount warning\\n' >&2\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        try await CodexActivityGuard(home: fixture.home, executable: script, timeout: 3)
            .requireQuiescent(lock: lock, desktopStopped: { true })
    }

    @Test func cancellingWaitsForTheOwnedInspectionChildToExit() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let script = fixture.root.appending(path: "lsof-fixture")
        let pidFile = fixture.root.appending(path: "owned-pid")
        try Data("#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let guard_ = CodexActivityGuard(home: fixture.home, executable: script, timeout: 10)
        let task = Task { try await guard_.requireQuiescent(lock: lock, desktopStopped: { true }) }
        defer { task.cancel() }
        let launchDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < launchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: pidFile.path), "The isolated inspection child must be running before cancellation")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func rootScopeSkipsHistoricalDirectoriesAndAllowsInstructionSymlinks() async throws {
        let fixture = try ActivityFixture()
        defer { fixture.clean() }
        let history = fixture.home.appending(path: "sessions")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        try Data("invalid history".utf8).write(to: history.appending(path: "broken.jsonl"))
        let outside = fixture.root.appending(path: "instructions.md")
        try Data("synthetic outside instructions".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: "AGENTS.md"), withDestinationURL: outside)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        try await CodexActivityGuard(home: fixture.home).requireQuiescent(lock: lock, desktopStopped: { true })
        await #expect(throws: CodexActivityError.self) {
            try await CodexActivityGuard(home: fixture.home).requireQuiescent(lock: lock, desktopStopped: { false })
        }
        lock.release()
        await #expect(throws: SourceFileError.self) {
            try await CodexActivityGuard(home: fixture.home).requireQuiescent(lock: lock, desktopStopped: { true })
        }
    }
}

private struct ActivityFixture {
    let root: URL, home: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "codex-activity-\(UUID())")
        home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
