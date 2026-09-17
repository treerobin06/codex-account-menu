import Foundation
import SQLite3
import Testing
@testable import SwitcherCore

struct ConversationCatalogTests {
    @Test func readsOnlyRecentUnarchivedMetadataWithoutChangingFiles() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let older = try fixture.add(title: "older", updated: 100)
        let newest = try fixture.add(title: "newest", updated: 300, provider: "copilot")
        _ = try fixture.add(title: "archived", updated: 500, archived: true)
        let before = try Data(contentsOf: fixture.database)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted()
        let summaries = try await fixture.catalog.recent()
        #expect(summaries.map(\.id) == [newest, older])
        #expect(summaries.map(\.title) == ["newest", "older"])
        #expect(summaries.first?.storedProvider == "copilot")
        #expect(summaries.allSatisfy { $0.sessionID == nil && $0.cwd == "/synthetic/project" })
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted() == names)
    }

    @Test func limitsAreBoundedAndZeroIsEmpty() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        for index in 0..<105 { _ = try fixture.add(title: "synthetic \(index)", updated: Int64(index)) }
        #expect(try await fixture.catalog.recent().count == 100)
        #expect(try await fixture.catalog.recent(limit: Int.max).count == 100)
        #expect(try await fixture.catalog.recent(limit: 2).map(\.title) == ["synthetic 104", "synthetic 103"])
        #expect(try await fixture.catalog.recent(limit: 0).isEmpty)
        #expect(try await fixture.catalog.recent(limit: -1).isEmpty)
    }

    @Test func millisecondTimestampsTakePriorityAndTiesAreStable() async throws {
        let fixture = try ConversationCatalogFixture(extraColumns: "updated_at_ms INTEGER")
        defer { fixture.clean() }
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        _ = try fixture.add(id: b, updated: 999)
        _ = try fixture.add(id: a, updated: 15)
        _ = try fixture.add(id: c, updated: 16)
        try fixture.exec("UPDATE threads SET updated_at_ms = 15000 WHERE id = '\(b.uuidString)'")
        let values = try await fixture.catalog.recent()
        #expect(values.map(\.id) == [c, a, b])
        #expect(values.last?.lastUpdatedAt == Date(timeIntervalSince1970: 15))
    }

    @Test func sessionIDComesOnlyFromAnExplicitColumn() async throws {
        let fixture = try ConversationCatalogFixture(extraColumns: "session_id TEXT")
        defer { fixture.clean() }
        let id = try fixture.add()
        #expect(try await fixture.catalog.recent().first?.sessionID == nil)
        try fixture.exec("UPDATE threads SET session_id = 'synthetic-session' WHERE id = '\(id.uuidString)'")
        #expect(try await fixture.catalog.recent().first?.sessionID == "synthetic-session")
    }

    @Test(arguments: ["title", "cwd", "archived", "updated_at", "model_provider", "rollout_path"])
    func missingRequiredColumnsFailClearly(column: String) async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        try fixture.exec("ALTER TABLE threads DROP COLUMN \(column)")
        await #expect(throws: ConversationCatalogError.incompatibleSchema) { try await fixture.catalog.recent() }
    }

    @Test func incompatibleOptionalSchemaAndViewsAreRejected() async throws {
        let fixture = try ConversationCatalogFixture(extraColumns: "updated_at_ms TEXT")
        defer { fixture.clean() }
        await #expect(throws: ConversationCatalogError.incompatibleSchema) { try await fixture.catalog.recent() }
        try fixture.exec("DROP TABLE threads; CREATE VIEW threads AS SELECT 'synthetic' AS id")
        await #expect(throws: ConversationCatalogError.incompatibleSchema) { try await fixture.catalog.recent() }
    }

    @Test func futureAndAmbiguousRootVersionsAreNotGuessed() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let future = fixture.home.appendingPathComponent("state_6.sqlite")
        try Data().write(to: future)
        await #expect(throws: ConversationCatalogError.ambiguousDatabases) { try await fixture.catalog.recent() }
        try FileManager.default.removeItem(at: fixture.database)
        await #expect(throws: ConversationCatalogError.unsupportedVersion) { try await fixture.catalog.recent() }
    }

    @Test func nestedHistoricalIndexIsIgnoredAndMissingRootIsExplicit() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let nested = fixture.home.appendingPathComponent("sqlite/state")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: nested.appendingPathComponent("state_5.sqlite"))
        #expect(try await fixture.catalog.recent().isEmpty)
        try FileManager.default.removeItem(at: fixture.database)
        await #expect(throws: ConversationCatalogError.databaseMissing) { try await fixture.catalog.recent() }
    }

    @Test func explicitAlternateLocationsAreRejected() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let override = ConversationCatalog(home: fixture.home, sqliteHomeOverride: fixture.home.appendingPathComponent("sqlite").path)
        await #expect(throws: ConversationCatalogError.unsupportedLocation) { try await override.recent() }
        let config = fixture.home.appendingPathComponent("config.toml")
        let original = Data("# synthetic only\n\"sqlite_home\" = '/elsewhere'\n".utf8)
        try original.write(to: config)
        await #expect(throws: ConversationCatalogError.unsupportedLocation) { try await fixture.catalog.recent() }
        #expect(try Data(contentsOf: config) == original)
    }

    @Test func symlinkHomeDatabaseAndSidecarsAreRejected() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let alias = fixture.home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let catalog = ConversationCatalog(home: alias, sqliteHomeOverride: nil)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await catalog.recent() }
        let sidecar = URL(fileURLWithPath: fixture.database.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: fixture.database)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.recent() }
        try FileManager.default.removeItem(at: sidecar)
        let saved = fixture.home.appendingPathComponent("original.sqlite")
        try FileManager.default.moveItem(at: fixture.database, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.database, withDestinationURL: saved)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.recent() }
    }

    @Test func invalidIdentityAndTimestampFailWithoutReturningOtherRows() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        _ = try fixture.add()
        try fixture.exec("UPDATE threads SET id = 'not-a-uuid'")
        await #expect(throws: ConversationCatalogError.malformedMetadata) { try await fixture.catalog.recent() }
        try fixture.exec("UPDATE threads SET id = '\(UUID().uuidString)', updated_at = -1")
        await #expect(throws: ConversationCatalogError.malformedMetadata) { try await fixture.catalog.recent() }
    }

    @Test func unavailableRolloutDoesNotBreakMetadataDirectory() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        _ = try fixture.add(rolloutPath: "/untrusted/missing.jsonl")
        let summary = try #require(try await fixture.catalog.recent().first)
        #expect(summary.rolloutPath == "/untrusted/missing.jsonl")
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.preview(for: summary) }
    }

    @Test func previewShowsPublicPromptAndFinalWithoutDuplicatingEventsOrReadingHiddenRoles() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let records: [[String: Any]] = [
            fixture.event("user_message", "duplicate prompt"),
            fixture.message("user", "public prompt"),
            fixture.message("system", "hidden system"),
            fixture.message("developer", "hidden developer"),
            fixture.message("tool", "hidden tool"),
            fixture.message("assistant", "hidden analysis", channel: "analysis"),
            fixture.message("assistant", "hidden reasoning", phase: "analysis"),
            fixture.message("assistant", "progress omitted", phase: "commentary"),
            ["type": "response_item", "payload": ["type": "reasoning", "summary": "hidden reasoning"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "channel": "final", "content": [
                ["type": "output_text", "text": "public final"],
                ["type": "image", "image_url": "data:image/png;base64,private-image"],
            ]]],
            fixture.event("agent_message", "duplicate final", phase: "final_answer"),
        ]
        let file = try fixture.rollout(id, records: records)
        let before = try Data(contentsOf: file)
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.map(\.text) == ["public prompt", "public final"])
        #expect(result.messages.map(\.role) == ["user", "assistant"])
        #expect(result.messages.first?.timestamp != nil)
        #expect(!result.limited)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func legacyEventFallbackFiltersPhasesAndHiddenEventTypes() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        _ = try fixture.rollout(id, records: [
            fixture.event("user_message", "legacy prompt"),
            fixture.event("agent_reasoning", "hidden"),
            fixture.event("agent_message", "hidden analysis", phase: "analysis"),
            fixture.event("agent_message", "legacy final", phase: "final_answer"),
        ])
        let summary = try #require(try await fixture.catalog.recent().first)
        #expect(try await fixture.catalog.preview(for: summary).messages.map(\.text) == ["legacy prompt", "legacy final"])
    }

    @Test func boundedTailSkipsTruncatedMultibyteAndOversizedLines() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        _ = try fixture.rollout(id, records: [
            fixture.message("user", String(repeating: "界", count: 200_000)),
            fixture.message("user", "latest prompt"),
            fixture.message("assistant", "latest final", channel: "final"),
        ])
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.map(\.text) == ["latest prompt", "latest final"])
        #expect(result.limited)
    }

    @Test func expandsPastLargeToolBlocksToRecentPublicPromptAndFinal() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        _ = try fixture.rollout(id, records: [
            fixture.message("tool", String(repeating: "old tool output ", count: 350_000)),
            fixture.message("assistant", "recent public final", channel: "final"),
            fixture.message("tool", String(repeating: "tool output ", count: 65_000)),
            fixture.message("user", "latest public prompt"),
            fixture.message("tool", String(repeating: "tool output ", count: 190_000)),
            fixture.message("assistant", "private analysis", channel: "analysis"),
            fixture.message("assistant", "progress is not a final", phase: "commentary"),
        ])
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.map(\.text) == ["recent public final", "latest public prompt"])
        #expect(result.messages.map(\.role) == ["assistant", "user"])
        #expect(result.limited) // The older part remains outside the 4 MiB window.
    }

    @Test(arguments: ["user", "assistant"])
    func expandsWhenTheSmallWindowContainsOnlyOnePublicRole(olderRole: String) async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let newerRole = olderRole == "user" ? "assistant" : "user"
        _ = try fixture.rollout(id, records: [
            fixture.message(olderRole, "earlier public message", channel: olderRole == "assistant" ? "final" : nil),
            fixture.message("tool", String(repeating: "界", count: 250_000)),
            fixture.message(newerRole, "latest public message", channel: newerRole == "assistant" ? "final" : nil),
        ])
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.map(\.text) == ["earlier public message", "latest public message"])
        #expect(!result.limited) // This entire short file fits within the expansion.
    }

    @Test func expansionStopsAtFourMiBEvenWhenPublicMessagesAreStillMissing() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let file = try fixture.rollout(id, records: [
            fixture.message("user", "prompt outside the maximum window"),
            fixture.message("assistant", "final outside the maximum window", channel: "final"),
            fixture.message("tool", String(repeating: "界", count: 1_500_000)),
            fixture.message("assistant", "commentary must remain excluded", phase: "commentary"),
        ])
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 4 * 1024 * 1024)
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.isEmpty)
        #expect(result.limited)
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size)
    }

    @Test func messageAndUnicodeTextLimitsAreHardBounds() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        var records = (0..<15).map { fixture.message("user", "message \($0)") }
        records.append(fixture.message("assistant", String(repeating: "树🌳", count: 1500), channel: "final"))
        _ = try fixture.rollout(id, records: records)
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary, limit: Int.max)
        #expect(result.messages.count == 12)
        #expect(result.messages.first?.text == "message 4")
        #expect(result.messages.last?.text.count == 2000)
        #expect(result.limited)
        #expect(try await fixture.catalog.preview(for: summary, limit: 0).messages.isEmpty)
    }

    @Test func encodedContentAndIncompleteLastLineAreOmitted() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let file = try fixture.rollout(id, records: [fixture.message("user", "image data:image/png;base64,QUJDREVGR0g= done")])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":".utf8)); try handle.close()
        let summary = try #require(try await fixture.catalog.recent().first)
        let result = try await fixture.catalog.preview(for: summary)
        #expect(result.messages.map(\.text) == ["image [二进制内容已省略] done"])
        #expect(result.limited)
    }

    @Test func previewRejectsMismatchedSessionMetadataAndUnboundedHeader() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let file = try fixture.rollout(id, records: [fixture.message("user", "private")], metadataID: UUID())
        let summary = try #require(try await fixture.catalog.recent().first)
        await #expect(throws: ConversationCatalogError.conversationMismatch) { try await fixture.catalog.preview(for: summary) }
        try Data(repeating: 32, count: 65_537).write(to: file)
        await #expect(throws: ConversationCatalogError.conversationMismatch) { try await fixture.catalog.preview(for: summary) }
    }

    @Test func previewRejectsTraversalAndSymlinkedFilesOrParents() async throws {
        let fixture = try ConversationCatalogFixture()
        defer { fixture.clean() }
        let id = try fixture.add()
        let file = try fixture.rollout(id, records: [fixture.message("user", "public")])
        let original = try #require(try await fixture.catalog.recent().first)
        let traversal = fixture.summary(original, path: fixture.home.path + "/sessions/../sessions/" + file.lastPathComponent)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.preview(for: traversal) }
        let alias = file.deletingLastPathComponent().appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let linked = fixture.summary(original, path: alias.path)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.preview(for: linked) }
        let parent = file.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: file.deletingLastPathComponent())
        let parentLinked = fixture.summary(original, path: parent.appendingPathComponent(file.lastPathComponent).path)
        await #expect(throws: ConversationCatalogError.unsafePath) { try await fixture.catalog.preview(for: parentLinked) }
    }
}

private struct ConversationCatalogFixture: Sendable {
    let home: URL
    let database: URL
    var catalog: ConversationCatalog { ConversationCatalog(home: home, sqliteHomeOverride: nil) }

    init(extraColumns: String? = nil) throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("conversation-catalog-\(UUID())")
        database = home.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let extra = extraColumns.map { ", " + $0 } ?? ""
        try exec("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, cwd TEXT NOT NULL, updated_at INTEGER NOT NULL, model_provider TEXT, archived INTEGER NOT NULL, rollout_path TEXT NOT NULL, first_user_message TEXT\(extra))")
    }

    func clean() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func add(id: UUID = UUID(), title: String = "synthetic title", updated: Int64 = 1,
             provider: String = "openai", archived: Bool = false, rolloutPath: String? = nil) throws -> UUID {
        let path = rolloutPath ?? home.appendingPathComponent("sessions/rollout-\(id.uuidString).jsonl").path
        try exec("INSERT INTO threads (id,title,cwd,updated_at,model_provider,archived,rollout_path,first_user_message) VALUES ('\(id.uuidString)','\(quote(title))','/synthetic/project',\(updated),'\(quote(provider))',\(archived ? 1 : 0),'\(quote(path))','unselected private body')")
        return id
    }

    func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw CatalogFixtureError.sqlite }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CatalogFixtureError.sqlite }
    }

    func rollout(_ id: UUID, records: [[String: Any]], metadataID: UUID? = nil) throws -> URL {
        let file = home.appendingPathComponent("sessions/rollout-\(id.uuidString).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": (metadataID ?? id).uuidString]]
        var bytes = Data()
        for record in [metadata] + records {
            bytes += try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            bytes.append(10)
        }
        try bytes.write(to: file)
        return file
    }

    func message(_ role: String, _ text: String, channel: String? = nil, phase: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]
        if let channel { payload["channel"] = channel }
        if let phase { payload["phase"] = phase }
        return ["type": "response_item", "timestamp": "2026-09-17T00:00:00.123Z", "payload": payload]
    }

    func event(_ type: String, _ message: String, phase: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": type, "message": message]
        if let phase { payload["phase"] = phase }
        return ["type": "event_msg", "payload": payload]
    }

    func summary(_ value: ConversationSummary, path: String) -> ConversationSummary {
        ConversationSummary(id: value.id, title: value.title, cwd: value.cwd, lastUpdatedAt: value.lastUpdatedAt,
            storedProvider: value.storedProvider, sessionID: value.sessionID, rolloutPath: path)
    }

    private func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}

private enum CatalogFixtureError: Error { case sqlite }
