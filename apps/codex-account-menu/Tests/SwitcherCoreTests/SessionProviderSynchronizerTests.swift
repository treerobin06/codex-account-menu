import Foundation
import SQLite3
import Testing
@testable import SwitcherCore

struct SessionProviderSynchronizerTests {
    @Test(arguments: ["openai", "copilot"])
    func readOnlyEstimateMatchesStablePlanWithoutWritingFiles(target: String) throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let original = try fixture.capture()
        let stateIdentity = try SourceFileIdentity.read(fixture.state)
        let catalogIdentity = try SourceFileIdentity.read(fixture.catalog)
        let sync = fixture.synchronizer()
        let plan = try sync.plan(targetProvider: target)
        let estimate = try sync.estimate(targetProvider: target)
        #expect(estimate.threadCount == plan.threads.count)
        #expect(estimate.backupBytesUpperBound == plan.backupBytesUpperBound)
        #expect(try fixture.capture() == original)
        #expect(try SourceFileIdentity.read(fixture.state) == stateIdentity)
        #expect(try SourceFileIdentity.read(fixture.catalog) == catalogIdentity)
        #expect(!FileManager.default.fileExists(atPath: sync.backupRoot.path))
        for update in 124..<127 {
            try fixture.exec(fixture.state, "UPDATE threads SET updated_at=\(update), title='ongoing conversation'")
            #expect(try sync.estimate(targetProvider: target).threadCount == estimate.threadCount)
        }
    }

    @Test func insufficientSpaceRejectsBeforeCreatingBackupsOrChangingMetadata() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let original = try fixture.capture()
        let sync = SessionProviderSynchronizer(home: fixture.home, availableSpace: { _ in 0 }, checkpoint: { _ in })
        let plan = try sync.plan()
        #expect(plan.requiredFreeSpaceUpperBound == plan.backupBytesUpperBound + plan.rolloutBytesToRewrite + 64 * 1024 * 1024)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        await #expect(throws: SessionProviderError.self) { try await sync.apply(plan, lock: lock, desktopStopped: { true }) }
        #expect(try fixture.capture() == original)
        #expect(!FileManager.default.fileExists(atPath: sync.backupRoot.path))
    }

    @Test func cleanNewHomeProducesAnEmptyReadOnlyPlan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("empty-session-plan-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let plan = try SessionProviderSynchronizer(home: home).plan()
        #expect(plan.isEmpty)
        #expect(plan.sqlitePaths.isEmpty)
        #expect(try SessionProviderSynchronizer(home: home).estimate().threadCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func previewIsReadOnlyAndApplyChangesOnlySelectedLocalMetadata() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let original = try fixture.capture()
        let sync = fixture.synchronizer()
        let plan = try sync.plan()
        #expect(plan.threads.map(\.id) == [fixture.b])
        #expect(try sync.estimate().threadCount == plan.threads.count)
        #expect(plan.sqlitePaths.count == 2)
        #expect(plan.rolloutBytesToRewrite == Int64(original.b.count))
        #expect(plan.backupBytesUpperBound > plan.rolloutBytesToRewrite)
        #expect(try fixture.capture() == original)
        #expect(!FileManager.default.fileExists(atPath: sync.backupRoot.path))
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let receipt = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        #expect(receipt.changedJSONLFiles == 1)
        #expect(receipt.changedSQLiteRows == 2)
        #expect(try Data(contentsOf: fixture.bFile) == fixture.bBytes.replacingMetadataProvider("copilot", with: "openai"))
        #expect(try Data(contentsOf: fixture.aFile) == original.a)
        #expect(try Data(contentsOf: fixture.otherFile) == original.other)
        #expect(try fixture.value(fixture.state, "SELECT model_provider FROM threads WHERE id='\(fixture.b.uuidString.lowercased())'") == "openai")
        #expect(try fixture.value(fixture.catalog, "SELECT model_provider FROM local_thread_catalog WHERE host_id='local'") == "openai")
        #expect(try fixture.value(fixture.catalog, "SELECT model_provider FROM local_thread_catalog WHERE host_id='remote'") == "copilot")
        #expect(try Data(contentsOf: fixture.config) == original.config)
        #expect(try Data(contentsOf: fixture.auth) == original.auth)
        let backup = try #require(receipt.backupDirectory)
        #expect(try (FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try (FileManager.default.attributesOfItem(atPath: backup.appendingPathComponent("rollout-0.jsonl").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await sync.rollback(receipt, lock: lock, desktopStopped: { true })
        #expect(try fixture.capture() == original)
    }

    @Test func explicitScopeCannotSilentlyIgnoreAnUnknownThread() throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        #expect(throws: SessionProviderError.self) { try fixture.synchronizer().plan(threadIDs: [UUID()]) }
        let plan = try fixture.synchronizer().plan(threadIDs: [fixture.a])
        #expect(plan.isEmpty)
        #expect(plan.skippedThreads.contains { $0.threadID.lowercased() == fixture.a.uuidString.lowercased() })
    }

    @Test func staleCatalogIsUpdatedEvenWhenCanonicalRowAlreadyUsesTarget() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        try fixture.exec(fixture.state, "UPDATE threads SET model_provider='openai' WHERE id='\(fixture.b.uuidString.lowercased())'")
        let bytes = fixture.bBytes.replacingMetadataProvider("copilot", with: "openai")
        try bytes.write(to: fixture.bFile)
        let sync = fixture.synchronizer(), plan = try sync.plan()
        #expect(plan.threads.map(\.id) == [fixture.b])
        #expect(plan.rolloutBytesToRewrite == 0)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let receipt = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        #expect(receipt.changedJSONLFiles == 0)
        #expect(receipt.changedSQLiteRows == 1)
        #expect(try Data(contentsOf: fixture.bFile) == bytes)
    }

    @Test func staleRolloutIsMigratedEvenWhenSQLiteAlreadyUsesTargetAndThereIsNoCatalog() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.catalog)
        try fixture.exec(fixture.state, "UPDATE threads SET model_provider='openai' WHERE id='\(fixture.b.uuidString.lowercased())'")
        let sync = SessionProviderSynchronizer(home: fixture.home)
        let plan = try sync.plan()
        #expect(plan.threads.map(\.id) == [fixture.b])
        #expect(plan.rolloutBytesToRewrite == Int64(fixture.bBytes.count))
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let receipt = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        #expect(receipt.changedJSONLFiles == 1)
        #expect(receipt.changedSQLiteRows == 0)
        #expect(try Data(contentsOf: fixture.bFile) == fixture.bBytes.replacingMetadataProvider("copilot", with: "openai"))
    }

    @Test func unrelatedSQLiteStoresAreNotOpenedAndUnknownStateVersionsAreRejected() throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        for name in ["memories_1.sqlite", "goals_1.sqlite", "logs_2.sqlite", "state_5.sqlite"] {
            try Data("intentionally not a database".utf8).write(to: fixture.home.appendingPathComponent("sqlite/" + name))
        }
        #expect(try fixture.synchronizer().plan().threads.map(\.id) == [fixture.b])
        try Data().write(to: fixture.home.appendingPathComponent("state_6.sqlite"))
        #expect(throws: SessionProviderError.self) { try fixture.synchronizer().plan() }
    }

    @Test func nativeInsertAndTimestampTriggersAreAllowedButProviderUpdateTriggersAreRejected() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        try fixture.exec(fixture.state, "CREATE TRIGGER native_insert AFTER INSERT ON threads BEGIN SELECT 1; END; CREATE TRIGGER native_timestamp AFTER UPDATE OF updated_at ON threads BEGIN SELECT 1; END")
        let sync = fixture.synchronizer(), plan = try sync.plan()
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        _ = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        try fixture.exec(fixture.state, "CREATE TRIGGER unsafe_provider AFTER UPDATE ON threads BEGIN UPDATE threads SET title='unexpected' WHERE id=NEW.id; END")
        #expect(throws: SessionProviderError.self) { try sync.plan() }
    }

    @Test(arguments: [false, true])
    func mutationFailureRollsBackAlreadyInstalledFilesAndCommittedDatabases(failAfterCommit: Bool) async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let original = try fixture.capture()
        let sync = fixture.synchronizer { point in
            switch point {
            case .fileInstalled where !failAfterCommit: throw SessionFixtureError.injected
            case .databaseCommitted where failAfterCommit: throw SessionFixtureError.injected
            default: break
            }
        }
        let plan = try sync.plan(), lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let failure = try #require(await migrationFailure { try await sync.apply(plan, lock: lock, desktopStopped: { true }) })
        #expect(failure.previousStateRestored)
        #expect(failure.backupDirectory != nil)
        #expect(try fixture.capture() == original)
    }

    @Test func failedApplyKeepsExternalRolloutChangesAndReportsIncompleteRecovery() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let external = fixture.bBytes + Data("{\"type\":\"event_msg\",\"payload\":\"external append\"}\n".utf8)
        let sync = fixture.synchronizer { point in
            if case .fileInstalled(let path) = point {
                try external.write(to: path, options: .atomic)
                throw SessionFixtureError.injected
            }
        }
        let plan = try sync.plan(), lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let failure = try #require(await migrationFailure { try await sync.apply(plan, lock: lock, desktopStopped: { true }) })
        #expect(!failure.previousStateRestored)
        #expect(try Data(contentsOf: fixture.bFile) == external)
        #expect(try fixture.value(fixture.state, "SELECT model_provider FROM threads WHERE id='\(fixture.b.uuidString.lowercased())'") == "copilot")
    }

    @Test func rollbackPreservesExternalSQLiteColumnsRatherThanOverwritingTheirRow() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let sync = fixture.synchronizer(), plan = try sync.plan()
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let receipt = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        try fixture.exec(fixture.state, "UPDATE threads SET title='external title' WHERE id='\(fixture.b.uuidString.lowercased())'")
        do {
            try await sync.rollback(receipt, lock: lock, desktopStopped: { true })
            Issue.record("Expected partial recovery")
        } catch let failure as SessionProviderFailure { #expect(!failure.previousStateRestored) }
        #expect(try fixture.value(fixture.state, "SELECT title FROM threads WHERE id='\(fixture.b.uuidString.lowercased())'") == "external title")
        #expect(try fixture.value(fixture.state, "SELECT model_provider FROM threads WHERE id='\(fixture.b.uuidString.lowercased())'") == "openai")
        #expect(try fixture.value(fixture.catalog, "SELECT model_provider FROM local_thread_catalog WHERE host_id='local'") == "copilot")
        #expect(try Data(contentsOf: fixture.bFile) == fixture.bBytes)
    }

    @Test(arguments: [false, true])
    func staleFileOrSQLitePlanIsRejectedBeforeMigration(sqlite: Bool) async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let sync = fixture.synchronizer(), plan = try sync.plan()
        if sqlite { try fixture.exec(fixture.state, "UPDATE threads SET title='changed before apply'") }
        else { try fixture.bBytes.write(to: fixture.bFile, options: .atomic) }
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        let failure = try #require(await migrationFailure { try await sync.apply(plan, lock: lock, desktopStopped: { true }) })
        #expect(failure.previousStateRestored)
        #expect(failure.backupDirectory == nil)
        #expect(try Data(contentsOf: fixture.bFile) == fixture.bBytes)
    }

    @Test func stoppedDesktopAndTheMatchingHeldLockAreMandatory() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let sync = fixture.synchronizer(), plan = try sync.plan()
        let lock = try SourceSwitchLock(home: fixture.home)
        await #expect(throws: SessionProviderError.self) { try await sync.apply(plan, lock: lock, desktopStopped: { false }) }
        lock.release()
        await #expect(throws: SourceFileError.self) { try await sync.apply(plan, lock: lock, desktopStopped: { true }) }
        #expect(!FileManager.default.fileExists(atPath: sync.backupRoot.path))
    }

    @Test func activeWriterIsRejectedEvenWhenCallerReportsDesktopStopped() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let sync = fixture.synchronizer(), plan = try sync.plan()
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sleep")
        writer.arguments = ["30"]
        let output = try FileHandle(forWritingTo: fixture.bFile)
        writer.standardOutput = output
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        try output.close()
        defer { if writer.isRunning { writer.terminate() }; writer.waitUntilExit() }
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        do {
            _ = try await sync.apply(plan, lock: lock, desktopStopped: { true })
            Issue.record("Expected active writer rejection")
        } catch SessionProviderError.activeWriter(let pids) { #expect(pids.contains(writer.processIdentifier)) }
        #expect(!FileManager.default.fileExists(atPath: sync.backupRoot.path))
    }

    @Test(arguments: ["foreign", "symlink", "sidecar", "schema", "metadata"])
    func unsupportedPathsAndSchemasFailClosed(kind: String) throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        switch kind {
        case "foreign":
            try fixture.exec(fixture.state, "UPDATE threads SET rollout_path='/tmp/foreign.jsonl' WHERE model_provider='copilot'")
        case "symlink":
            try FileManager.default.removeItem(at: fixture.bFile)
            try FileManager.default.createSymbolicLink(at: fixture.bFile, withDestinationURL: fixture.aFile)
        case "sidecar":
            try FileManager.default.createSymbolicLink(atPath: fixture.state.path + "-wal", withDestinationPath: fixture.home.appendingPathComponent("missing").path)
        case "schema":
            try fixture.exec(fixture.state, "ALTER TABLE threads RENAME COLUMN rollout_path TO unsupported_path")
        default:
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.b.uuidString)\",\"model_provider\":\"copilot\",\"model_provider\":\"copilot\"}}\n".utf8).write(to: fixture.bFile)
        }
        #expect(throws: (any Error).self) { try fixture.synchronizer().plan() }
        #expect(throws: (any Error).self) { try fixture.synchronizer().estimate() }
        #expect(!FileManager.default.fileExists(atPath: fixture.synchronizer().backupRoot.path))
    }

    @Test func largeRolloutAndReplayedParentMetadataKeepEveryMessageByte() async throws {
        let fixture = try SessionMigrationFixture()
        defer { fixture.clean() }
        let parent = SessionMigrationFixture.metadata(UUID(), provider: "unmanaged-parent")
        let message = Data(("{\"type\":\"response_item\",\"payload\":{\"encrypted_content\":\"" + String(repeating: "x", count: 256 * 1024) + "\"}}\n").utf8)
        let output = try FileHandle(forWritingTo: fixture.bFile)
        try output.seekToEnd()
        try output.write(contentsOf: parent)
        for _ in 0..<32 { try output.write(contentsOf: message) }
        try output.close()
        let original = try Data(contentsOf: fixture.bFile)
        let sync = fixture.synchronizer(), plan = try sync.plan()
        #expect(plan.rolloutBytesToRewrite > 8 * 1024 * 1024)
        let lock = try SourceSwitchLock(home: fixture.home)
        defer { lock.release() }
        _ = try await sync.apply(plan, lock: lock, desktopStopped: { true })
        #expect(try Data(contentsOf: fixture.bFile) == original.replacingMetadataProvider("copilot", with: "openai"))
    }
}

private enum SessionFixtureError: Error { case injected, sqlite }

private func migrationFailure(_ operation: () async throws -> SessionProviderReceipt) async -> SessionProviderFailure? {
    do { _ = try await operation(); Issue.record("Expected migration failure"); return nil }
    catch let failure as SessionProviderFailure { return failure }
    catch { Issue.record("Unexpected migration error: \(error)"); return nil }
}

private extension Data {
    func replacingMetadataProvider(_ source: String, with target: String) -> Data {
        let before = Data("\"model_provider\":\"\(source)\"".utf8)
        let after = Data("\"model_provider\":\"\(target)\"".utf8)
        var result = self
        if let range = result.range(of: before) { result.replaceSubrange(range, with: after) }
        return result
    }
}

private struct SessionMigrationSnapshot: Equatable {
    let a: Data, b: Data, other: Data, config: Data, auth: Data
    let stateRows: String, catalogRows: String
}

private struct SessionMigrationFixture: Sendable {
    let home: URL, state: URL, catalog: URL, aFile: URL, bFile: URL, otherFile: URL, auth: URL, config: URL
    let a = UUID(), b = UUID(), other = UUID()
    let bBytes: Data

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("session-migration-test-\(UUID())")
        state = home.appendingPathComponent("state_5.sqlite")
        catalog = home.appendingPathComponent("sqlite/codex-paginated.db")
        aFile = home.appendingPathComponent("sessions/rollout-\(a.uuidString).jsonl")
        bFile = home.appendingPathComponent("sessions/rollout-\(b.uuidString).jsonl")
        otherFile = home.appendingPathComponent("archived_sessions/rollout-\(other.uuidString).jsonl")
        auth = home.appendingPathComponent("auth.json")
        config = home.appendingPathComponent("config.toml")
        for directory in [home, aFile.deletingLastPathComponent(), otherFile.deletingLastPathComponent(), catalog.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("fixture auth remains private and unchanged".utf8).write(to: auth)
        try Data("model_provider = \"copilot\"\n".utf8).write(to: config)
        try Self.metadata(a, provider: "openai").write(to: aFile)
        bBytes = Self.metadata(b, provider: "copilot") + Data("{\"type\":\"response_item\",\"payload\":{\"encrypted_content\":\"opaque-original\",\"text\":\"keep \\\"model_provider\\\":\\\"copilot\\\" untouched\"}}\r\n".utf8)
        try bBytes.write(to: bFile)
        try Self.metadata(other, provider: "other").write(to: otherFile)
        try Self.sql(state, "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, rollout_path TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)")
        for (id, provider, path) in [(a, "openai", aFile), (b, "copilot", bFile), (other, "other", otherFile)] {
            try Self.sql(state, "INSERT INTO threads VALUES('\(id.uuidString.lowercased())','\(provider)','\(path.path)','original title',123)")
        }
        try Self.sql(catalog, "CREATE TABLE local_thread_catalog_hosts(host_id TEXT PRIMARY KEY, host_kind TEXT); INSERT INTO local_thread_catalog_hosts VALUES('local','local'),('remote','remote'); CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT, model_provider TEXT, display_title TEXT, PRIMARY KEY(host_id,thread_id)); INSERT INTO local_thread_catalog VALUES('local','\(b.uuidString.lowercased())','copilot','original title'),('remote','\(b.uuidString.lowercased())','copilot','remote title')")
    }

    static func metadata(_ id: UUID, provider: String) -> Data {
        Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id.uuidString.lowercased())\",\"model_provider\":\"\(provider)\",\"cwd\":\"/fixture\"}}\n".utf8)
    }
    func synchronizer(checkpoint: @escaping @Sendable (SessionMigrationCheckpoint) throws -> Void = { _ in }) -> SessionProviderSynchronizer {
        SessionProviderSynchronizer(home: home, catalogDatabases: [catalog], checkpoint: checkpoint)
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
    func exec(_ path: URL, _ query: String) throws { try Self.sql(path, query) }
    func value(_ path: URL, _ query: String) throws -> String { try Self.read(path, query).joined(separator: "\n") }
    func capture() throws -> SessionMigrationSnapshot {
        try .init(a: Data(contentsOf: aFile), b: Data(contentsOf: bFile), other: Data(contentsOf: otherFile), config: Data(contentsOf: config), auth: Data(contentsOf: auth),
            stateRows: value(state, "SELECT id||'|'||model_provider||'|'||rollout_path||'|'||title||'|'||updated_at FROM threads ORDER BY id"),
            catalogRows: value(catalog, "SELECT host_id||'|'||thread_id||'|'||model_provider||'|'||display_title FROM local_thread_catalog ORDER BY host_id"))
    }
    private static func sql(_ path: URL, _ query: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw SessionFixtureError.sqlite }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw SessionFixtureError.sqlite }
    }
    private static func read(_ path: URL, _ query: String) throws -> [String] {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SessionFixtureError.sqlite }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw SessionFixtureError.sqlite }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }
}
