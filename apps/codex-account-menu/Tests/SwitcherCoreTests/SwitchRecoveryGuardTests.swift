import Foundation
import Testing
@testable import SwitcherCore

@Suite(.serialized)
struct SwitchRecoveryGuardTests {
    @Test func missingStateQueryIsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-recovery-test-\(UUID())")
        let guarder = SwitchRecoveryGuard(baseURL: root.appendingPathComponent("state"), home: root.appendingPathComponent("home"))
        #expect(try guarder.pendingRecord() == nil)
        try guarder.requireSafeAutomaticWork()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func pendingRecordSurvivesNewInstanceAndBindsCanonicalHome() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.home)
        let lock = try SourceSwitchLock(home: alias)
        defer { lock.release() }
        let first = SwitchRecoveryGuard(baseURL: f.base, home: alias)
        _ = try first.begin(first.prepare(lock: lock), lock: lock)
        let second = SwitchRecoveryGuard(baseURL: f.base, home: f.home)
        let record = try #require(try second.pendingRecord())
        #expect(record.canonicalHome == f.home.resolvingSymlinksInPath().path)
        #expect(record.version == 1)
        #expect(throws: SourceSwitchRecoveryError.self) { try second.requireSafeAutomaticWork() }
        let bytes = try Data(contentsOf: second.recordURL)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["version", "transactionID", "canonicalHome", "startedAt"])
        let permissions = try FileManager.default.attributesOfItem(atPath: second.recordURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func publicationRequiresMatchingHeldLockAndConcurrentSwitchCannotEnter() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let lock = try SourceSwitchLock(home: f.home)
        let checkpoint = try f.guarder.prepare(lock: lock)
        #expect(throws: SourceFileError.self) { _ = try SourceSwitchLock(home: f.home) }
        let other = SwitchRecoveryGuard(baseURL: f.base, home: f.root.appendingPathComponent("other-home"))
        #expect(throws: SourceFileError.self) { _ = try other.prepare(lock: lock) }
        lock.release()
        #expect(throws: SourceFileError.self) { _ = try f.guarder.begin(checkpoint, lock: lock) }
        #expect(try f.guarder.pendingRecord() == nil)
    }

    @Test func failureBeforePublicationLeavesNoPendingRecord() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let lock = try SourceSwitchLock(home: f.home)
        defer { lock.release() }
        let checkpoint = try f.guarder.prepare(lock: lock)
        let moved = f.root.appendingPathComponent("moved-state")
        try FileManager.default.moveItem(at: f.base, to: moved)
        #expect(throws: (any Error).self) { _ = try f.guarder.begin(checkpoint, lock: lock) }
        #expect(try f.guarder.pendingRecord() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    @Test func recoveringANewAttemptCannotAcknowledgeInheritedPendingState() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let lock = try SourceSwitchLock(home: f.home)
        defer { lock.release() }
        _ = try f.guarder.begin(f.guarder.prepare(lock: lock), lock: lock)
        let before = try SourceFileSnapshot.read(f.guarder.recordURL)
        let renewed = SwitchRecoveryGuard(baseURL: f.base, home: f.home)
        let inherited = try renewed.begin(renewed.prepare(lock: lock), lock: lock)
        #expect(inherited.inheritedPending)
        try renewed.complete(inherited, recoveredPreviousState: true, lock: lock)
        try before.requireUnchanged()
        try renewed.complete(inherited, recoveredPreviousState: false, lock: lock)
        #expect(try renewed.pendingRecord() == nil)
    }

    @Test func lateCompletionCannotRemoveANewerPendingRecord() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let lock = try SourceSwitchLock(home: f.home)
        defer { lock.release() }
        let first = try f.guarder.begin(f.guarder.prepare(lock: lock), lock: lock)
        try f.guarder.complete(first, recoveredPreviousState: false, lock: lock)
        _ = try f.guarder.begin(f.guarder.prepare(lock: lock), lock: lock)
        let newer = try SourceFileSnapshot.read(f.guarder.recordURL)
        #expect(throws: SourceFileError.self) { try f.guarder.complete(first, recoveredPreviousState: false, lock: lock) }
        try newer.requireUnchanged()
    }

    @Test func foreignAndMalformedRecordsArePreservedAndBlockAutomaticWork() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let otherHome = f.root.appendingPathComponent("other-home")
        let foreign = try JSONEncoder().encode(SourceSwitchPendingRecord(home: otherHome))
        for bytes in [foreign, Data("{invalid".utf8)] {
            try bytes.write(to: f.guarder.recordURL, options: .atomic)
            let before = try SourceFileSnapshot.read(f.guarder.recordURL)
            #expect(throws: SourceSwitchRecoveryError.self) { try f.guarder.requireSafeAutomaticWork() }
            try before.requireUnchanged()
        }
    }

    @Test func replacedCheckpointAndSymlinkRecordAreNeverClaimed() throws {
        let f = try RecoveryGuardFixture()
        defer { f.clean() }
        let lock = try SourceSwitchLock(home: f.home)
        defer { lock.release() }
        let checkpoint = try f.guarder.prepare(lock: lock)
        let foreign = try JSONEncoder().encode(SourceSwitchPendingRecord(home: f.home))
        try foreign.write(to: f.guarder.recordURL)
        #expect(throws: SourceFileError.self) { _ = try f.guarder.begin(checkpoint, lock: lock) }
        #expect(try Data(contentsOf: f.guarder.recordURL) == foreign)
        let destination = f.root.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: destination)
        try FileManager.default.removeItem(at: f.guarder.recordURL)
        try FileManager.default.createSymbolicLink(at: f.guarder.recordURL, withDestinationURL: destination)
        #expect(throws: SourceFileError.self) { _ = try f.guarder.pendingRecord() }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "untouched")
    }
}

private struct RecoveryGuardFixture {
    let root: URL, base: URL, home: URL
    var guarder: SwitchRecoveryGuard { SwitchRecoveryGuard(baseURL: base, home: home) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-recovery-test-\(UUID())")
        base = root.appendingPathComponent("state")
        home = root.appendingPathComponent("home")
        for directory in [base, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
