import Darwin
import Foundation
import SQLite3

/// Local index metadata only. A stored provider is not evidence of current billing.
public struct ConversationSummary: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let cwd: String
    public let lastUpdatedAt: Date
    public let storedProvider: String?
    public let sessionID: String?
    public let rolloutPath: String

    public init(id: UUID, title: String, cwd: String, lastUpdatedAt: Date,
                storedProvider: String?, sessionID: String? = nil, rolloutPath: String) {
        self.id = id; self.title = title; self.cwd = cwd
        self.lastUpdatedAt = lastUpdatedAt; self.storedProvider = storedProvider
        self.sessionID = sessionID
        self.rolloutPath = rolloutPath
    }
}

public struct ConversationMessagePreview: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?

    public init(id: String, role: String, text: String, timestamp: Date?) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
    }
}

public struct ConversationPreview: Codable, Sendable, Equatable {
    public let messages: [ConversationMessagePreview]
    public let limited: Bool

    public init(messages: [ConversationMessagePreview], limited: Bool) {
        self.messages = messages; self.limited = limited
    }
}

public enum ConversationCatalogError: LocalizedError, Equatable, Sendable {
    case unsafePath, databaseMissing, ambiguousDatabases, unsupportedVersion
    case unsupportedLocation, incompatibleSchema, malformedMetadata, databaseUnavailable
    case previewUnavailable, conversationMismatch

    public var errorDescription: String? {
        switch self {
        case .unsafePath: "对话目录路径不可信，已停止读取。"
        case .databaseMissing: "当前 Codex 根目录没有已核验的对话索引。"
        case .ambiguousDatabases: "发现多个根目录对话索引，需先核验当前使用的版本。"
        case .unsupportedVersion: "对话索引版本已变化，需重新核验后读取。"
        case .unsupportedLocation: "配置指定了其他对话索引位置，需先核验实际位置。"
        case .incompatibleSchema: "对话索引结构已变化，已停止读取。"
        case .malformedMetadata: "对话索引中的元数据无法确认，已停止读取。"
        case .databaseUnavailable: "对话索引暂时无法只读访问，请稍后重试。"
        case .previewUnavailable: "该对话的本地预览暂不可用；没有读取其他对话。"
        case .conversationMismatch: "对话文件与所选任务身份不一致，已停止预览。"
        }
    }
}

/// Reads one verified root index and, only on selection, a bounded public-message
/// preview. It never calls the runtime or keeps a second message database.
public actor ConversationCatalog {
    private let home: URL
    private let sqliteHomeOverride: String?

    public init(home: URL) {
        self.home = home
        sqliteHomeOverride = ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"]
    }

    init(home: URL, sqliteHomeOverride: String?) {
        self.home = home; self.sqliteHomeOverride = sqliteHomeOverride
    }

    public func recent(limit: Int = 100) throws -> [ConversationSummary] {
        let directory = home.standardizedFileURL
        guard home.isFileURL, directory.path.hasPrefix("/"),
              directory.resolvingSymlinksInPath() == directory else {
            throw ConversationCatalogError.unsafePath
        }
        let rootIdentity = try CatalogPathIdentity.read(directory, directory: true)
        if let raw = sqliteHomeOverride, !raw.isEmpty,
           URL(fileURLWithPath: raw).standardizedFileURL != directory {
            throw ConversationCatalogError.unsupportedLocation
        }
        try requireDefaultLocation(in: directory)
        // Deliberately do not descend into old sqlite/, state/, or rollout trees.
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        guard !candidates.isEmpty else { throw ConversationCatalogError.databaseMissing }
        guard candidates.count == 1 else { throw ConversationCatalogError.ambiguousDatabases }
        let path = candidates[0]
        guard path.lastPathComponent == "state_5.sqlite" else { throw ConversationCatalogError.unsupportedVersion }
        let databaseIdentity = try CatalogPathIdentity.read(path)
        try validateSidecars(path)
        let database = try CatalogSQLite(path: path)
        defer { database.close() }
        let summaries = try database.recent(limit: min(max(limit, 0), 100))
        guard try CatalogPathIdentity.read(directory, directory: true) == rootIdentity,
              try CatalogPathIdentity.read(path) == databaseIdentity,
              directory.resolvingSymlinksInPath() == directory else {
            throw ConversationCatalogError.unsafePath
        }
        try validateSidecars(path)
        return summaries
    }

    public func preview(for conversation: ConversationSummary, limit: Int = 12) throws -> ConversationPreview {
        let directory = home.standardizedFileURL
        guard home.isFileURL, directory.resolvingSymlinksInPath() == directory else {
            throw ConversationCatalogError.unsafePath
        }
        _ = try CatalogPathIdentity.read(directory, directory: true)
        let path = URL(fileURLWithPath: conversation.rolloutPath).standardizedFileURL
        guard path.path == conversation.rolloutPath, path.pathExtension == "jsonl",
              ["sessions", "archived_sessions"].contains(where: {
                  path.path.hasPrefix(directory.appendingPathComponent($0).path + "/")
              }), path.resolvingSymlinksInPath() == path else {
            throw ConversationCatalogError.unsafePath
        }
        let identity = try CatalogPathIdentity.read(path)
        let fd = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ConversationCatalogError.previewUnavailable }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == identity.device, info.st_ino == identity.inode, info.st_size >= 0 else {
            throw ConversationCatalogError.unsafePath
        }
        let length = Int64(info.st_size)
        let header = try catalogRead(fd, offset: 0, count: Int(min(length, 65_536)))
        guard let newline = header.firstIndex(of: 10),
              let metadata = try? JSONSerialization.jsonObject(with: header.prefix(upTo: newline)) as? [String: Any],
              metadata["type"] as? String == "session_meta",
              let payload = metadata["payload"] as? [String: Any],
              let rawID = payload["id"] as? String, UUID(uuidString: rawID) == conversation.id else {
            throw ConversationCatalogError.conversationMismatch
        }
        let messageLimit = min(max(limit, 0), 12)
        let tail = try catalogReadTail(fd, length: length, maximumBytes: 512 * 1024)
        var result = catalogPreviewTail(tail, id: conversation.id, limit: messageLimit)
        if messageLimit > 0, tail.offset > 0,
           !(result.messages.contains { $0.role == "user" } && result.messages.contains { $0.role == "assistant" }) {
            // Long tool/analysis blocks can separate recent public messages.
            // Read only the missing prefix, so total tail I/O never exceeds
            // 4 MiB; the already-read final 512 KiB is reused unchanged.
            let expanded = try catalogReadTail(fd, length: length, maximumBytes: 4 * 1024 * 1024, suffix: tail)
            result = catalogPreviewTail(expanded, id: conversation.id, limit: messageLimit)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size >= info.st_size,
              try CatalogPathIdentity.read(path) == identity,
              path.resolvingSymlinksInPath() == path else {
            throw ConversationCatalogError.previewUnavailable
        }
        return result
    }

    private func requireDefaultLocation(in directory: URL) throws {
        let config = directory.appendingPathComponent("config.toml")
        guard try CatalogPathIdentity.optional(config) != nil else { return }
        // Match declarations only; never expose configuration values in errors.
        let text = try String(contentsOf: config, encoding: .utf8)
        let declaration = try NSRegularExpression(pattern: "(?m)^\\s*(?:sqlite_home|[\"']sqlite_home[\"'])\\s*=")
        if declaration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            throw ConversationCatalogError.unsupportedLocation
        }
    }

    private func validateSidecars(_ path: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            _ = try CatalogPathIdentity.optional(URL(fileURLWithPath: path.path + suffix))
        }
    }
}

private struct CatalogPathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    static func read(_ path: URL, directory: Bool = false) throws -> Self {
        guard let identity = try optional(path, directory: directory) else {
            throw ConversationCatalogError.unsafePath
        }
        return identity
    }

    static func optional(_ path: URL, directory: Bool = false) throws -> Self? {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ConversationCatalogError.unsafePath
        }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              info.st_uid == getuid() else { throw ConversationCatalogError.unsafePath }
        return Self(device: info.st_dev, inode: info.st_ino)
    }
}

private final class CatalogSQLite {
    private var connection: OpaquePointer?
    private static let required: [String: String] = [
        "id": "TEXT", "title": "TEXT", "cwd": "TEXT", "updated_at": "INTEGER",
        "model_provider": "TEXT", "archived": "INTEGER", "rollout_path": "TEXT",
    ]

    init(path: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path.path, &connection, flags, nil) == SQLITE_OK else {
            close(); throw ConversationCatalogError.databaseUnavailable
        }
        sqlite3_busy_timeout(connection, 250)
        guard sqlite3_db_readonly(connection, "main") == 1,
              sqlite3_exec(connection, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK else {
            close(); throw ConversationCatalogError.databaseUnavailable
        }
    }

    func close() {
        if let connection { sqlite3_close_v2(connection); self.connection = nil }
    }
    deinit { close() }

    func recent(limit: Int) throws -> [ConversationSummary] {
        let columns = try schema()
        let hasMilliseconds = columns.contains("updated_at_ms")
        let hasSessionID = columns.contains("session_id")
        let milliseconds = hasMilliseconds ? "updated_at_ms" : "NULL"
        let sessionID = hasSessionID ? "session_id" : "NULL"
        let ordering = hasMilliseconds ? "COALESCE(updated_at_ms / 1000.0, updated_at)" : "updated_at"
        let sql = """
            SELECT id, title, cwd, updated_at, \(milliseconds), model_provider, \(sessionID), rollout_path
            FROM threads WHERE archived = 0 ORDER BY \(ordering) DESC, id ASC LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
              sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
            throw ConversationCatalogError.databaseUnavailable
        }
        var result: [ConversationSummary] = []
        while try step(statement) {
            guard let rawID = try text(statement, 0), let id = UUID(uuidString: rawID),
                  let title = try text(statement, 1), let cwd = try text(statement, 2),
                  let rolloutPath = try text(statement, 7),
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
                throw ConversationCatalogError.malformedMetadata
            }
            let seconds: Double
            if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                seconds = Double(sqlite3_column_int64(statement, 3))
            } else {
                guard sqlite3_column_type(statement, 4) == SQLITE_INTEGER else {
                    throw ConversationCatalogError.malformedMetadata
                }
                seconds = Double(sqlite3_column_int64(statement, 4)) / 1000
            }
            guard seconds >= 0, seconds <= 253_402_300_799 else {
                throw ConversationCatalogError.malformedMetadata
            }
            result.append(try ConversationSummary(id: id, title: title, cwd: cwd,
                lastUpdatedAt: Date(timeIntervalSince1970: seconds),
                storedProvider: text(statement, 5), sessionID: text(statement, 6), rolloutPath: rolloutPath))
        }
        return result
    }

    private func schema() throws -> Set<String> {
        // Reject views and virtual tables; no extension or generated expression
        // should turn a metadata query into a different source of information.
        let table = try prepare("SELECT type, sql FROM sqlite_schema WHERE name = 'threads'")
        defer { sqlite3_finalize(table) }
        guard try step(table), try text(table, 0) == "table", let definition = try text(table, 1),
              definition.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CREATE TABLE") else {
            throw ConversationCatalogError.incompatibleSchema
        }
        let statement = try prepare("PRAGMA table_xinfo(threads)")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while try step(statement) {
            guard let name = try text(statement, 1), let type = try text(statement, 2) else {
                throw ConversationCatalogError.incompatibleSchema
            }
            let expected = Self.required[name] ?? (name == "updated_at_ms" ? "INTEGER" : name == "session_id" ? "TEXT" : nil)
            if let expected {
                guard type.uppercased() == expected, sqlite3_column_int(statement, 6) == 0,
                      name != "id" || sqlite3_column_int(statement, 5) > 0 else {
                    throw ConversationCatalogError.incompatibleSchema
                }
                columns.insert(name)
            }
        }
        guard Set(Self.required.keys).isSubset(of: columns) else {
            throw ConversationCatalogError.incompatibleSchema
        }
        return columns
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ConversationCatalogError.databaseUnavailable
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ConversationCatalogError.databaseUnavailable
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else {
            throw ConversationCatalogError.malformedMetadata
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= 65_536, let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
            throw ConversationCatalogError.malformedMetadata
        }
        return value
    }
}

private func catalogRead(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
        let amount = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
        }
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw ConversationCatalogError.previewUnavailable }
        received += amount
    }
    return Data(bytes)
}

private struct CatalogTail {
    let bytes: Data
    let offset: Int64
}

private func catalogReadTail(_ descriptor: Int32, length: Int64, maximumBytes: Int,
                             suffix: CatalogTail? = nil) throws -> CatalogTail {
    let offset = max(0, length - Int64(maximumBytes))
    if let suffix {
        let prefix = try catalogRead(descriptor, offset: offset, count: Int(suffix.offset - offset))
        return CatalogTail(bytes: prefix + suffix.bytes, offset: offset)
    }
    return CatalogTail(bytes: try catalogRead(descriptor, offset: offset, count: Int(length - offset)), offset: offset)
}

private func catalogPreviewTail(_ tail: CatalogTail, id: UUID, limit: Int) -> ConversationPreview {
    var bytes = tail.bytes
    var offset = tail.offset
    // Cutting raw bytes at a newline also removes an incomplete UTF-8 scalar.
    if offset > 0 {
        if let boundary = bytes.firstIndex(of: 10) {
            let removed = bytes.distance(from: bytes.startIndex, to: boundary) + 1
            bytes = Data(bytes.dropFirst(removed)); offset += Int64(removed)
        } else { bytes = Data() }
    }
    return catalogPreview(bytes, initialOffset: offset, id: id, limit: limit, limited: tail.offset > 0)
}

private func catalogPreview(_ bytes: Data, initialOffset: Int64, id: UUID,
                            limit: Int, limited initialLimited: Bool) -> ConversationPreview {
    let timestamp = ISO8601DateFormatter()
    timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let simpleTimestamp = ISO8601DateFormatter()
    let encoded = try? NSRegularExpression(pattern: "data:[^\\s]*;base64,[A-Za-z0-9+/=_-]+|[A-Za-z0-9+/]{256,}={0,2}")
    var responseMessages: [ConversationMessagePreview] = []
    var fallbackMessages: [ConversationMessagePreview] = []
    var limited = initialLimited
    var offset = initialOffset

    for line in bytes.split(separator: 10, omittingEmptySubsequences: false) {
        defer { offset += Int64(line.count) + 1 }
        guard !line.isEmpty else { continue }
        guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = item["payload"] as? [String: Any] else {
            limited = true; continue
        }
        let kind = item["type"] as? String
        var role: String?
        var parts: [String] = []
        let response = kind == "response_item"
        if response, payload["type"] as? String == "message",
           let candidate = payload["role"] as? String, ["user", "assistant"].contains(candidate),
           catalogPublicPhase(payload), catalogPublicPhase(item),
           let content = payload["content"] as? [[String: Any]] {
            role = candidate
            parts = content.compactMap { part in
                guard let type = part["type"] as? String,
                      ["input_text", "output_text", "text"].contains(type) else { return nil }
                return part["text"] as? String
            }
        } else if kind == "event_msg", catalogPublicPhase(payload), catalogPublicPhase(item),
                  let type = payload["type"] as? String, ["user_message", "agent_message"].contains(type),
                  let message = payload["message"] as? String {
            role = type == "user_message" ? "user" : "assistant"
            parts = [message]
        }
        guard let role, !parts.isEmpty else { continue }
        var text = parts.joined(separator: "\n")
        if let encoded {
            let safe = encoded.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "[二进制内容已省略]")
            if safe != text { limited = true; text = safe }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        if text.count > 2000 { text = String(text.prefix(1999)) + "…"; limited = true }
        let date = (item["timestamp"] as? String).flatMap { timestamp.date(from: $0) ?? simpleTimestamp.date(from: $0) }
        let message = ConversationMessagePreview(id: "\(id.uuidString.lowercased()):\(offset)",
            role: role, text: text, timestamp: date)
        if response { responseMessages.append(message) }
        else { fallbackMessages.append(message) }
    }
    // Legacy event messages are a fallback for a tail with no public message
    // items. Combining both streams would duplicate the same prompt/answer.
    let candidates = responseMessages.isEmpty ? fallbackMessages : responseMessages
    return ConversationPreview(messages: Array(candidates.suffix(limit)), limited: limited || candidates.count > limit)
}

private func catalogPublicPhase(_ value: [String: Any]) -> Bool {
    for (key, allowed) in [("channel", ["final"]), ("phase", ["final", "final_answer"])] {
        guard let raw = value[key], !(raw is NSNull) else { continue }
        guard let text = raw as? String, allowed.contains(text) else { return false }
    }
    return true
}
