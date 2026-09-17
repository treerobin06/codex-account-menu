import Foundation
import CryptoKit
import Darwin
import SQLite3

// Original implementation. Design references only (no implementation copied):
// CC Switch v3.20.3, codex_history_migration.rs (MIT), and
// CodexPlusPlus v1.3.0, provider_sync.rs (AGPL-3.0).
// This module changes provider metadata, never messages, encrypted reasoning,
// thread identifiers, authentication, or provider configuration.

public struct SessionProviderThread: Sendable, Equatable {
    public let id: UUID
    public let rollout: URL
    public let previousProviders: [String]
    public let bytes: Int64
}

public struct SessionProviderSkip: Sendable, Equatable {
    public let threadID: String
    public let reason: String
}

/// Read-only UI sizing, deliberately not an authorization or an applicable plan.
/// Live threads may append data between this estimate and the stopped-app plan.
public struct SessionProviderEstimate: Sendable, Equatable {
    public let threadCount: Int
    public let backupBytesUpperBound: Int64
}

public struct SessionProviderPlan: Sendable {
    public let id: UUID
    public let home: URL
    public let targetProvider: String
    public let threads: [SessionProviderThread]
    public let skippedThreads: [SessionProviderSkip]
    public let sqlitePaths: [URL]
    public let rolloutBytesToRewrite: Int64
    /// Conservative logical bytes; APFS cloning may use substantially less space.
    public let backupBytesUpperBound: Int64
    /// Includes a conservative allowance for rewritten files and SQLite journals.
    public var requiredFreeSpaceUpperBound: Int64 { backupBytesUpperBound + rolloutBytesToRewrite + 64 * 1024 * 1024 }
    public var isEmpty: Bool { threads.isEmpty }
    fileprivate let databases: [SessionDatabasePlan]
    fileprivate let files: [SessionRolloutPlan]
    fileprivate let unchangedFiles: [SessionUnchangedFile]
    fileprivate let inspectedSQLitePaths: [URL]
}

public struct SessionProviderReceipt: Sendable {
    public let plan: SessionProviderPlan
    public let backupDirectory: URL?
    public let changedJSONLFiles: Int
    public let changedSQLiteRows: Int
    fileprivate let files: [SessionInstalledFile]
    fileprivate let committedDatabases: [URL]
}

public struct SessionProviderFailure: LocalizedError, Sendable {
    public let cause: String
    public let backupDirectory: URL?
    public let rollbackErrors: [String]
    public var previousStateRestored: Bool { rollbackErrors.isEmpty }
    public var errorDescription: String? {
        let recovery = rollbackErrors.isEmpty ? "Previous session metadata was restored." : "Recovery is incomplete: " + rollbackErrors.joined(separator: "; ")
        return "Session provider migration failed: \(cause) \(recovery)" + (backupDirectory.map { " Backup: \($0.path)" } ?? "")
    }
}

public enum SessionProviderError: LocalizedError, Sendable {
    case invalid(String), changed(String), activeWriter([Int32]), desktopRunning
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): "Unsupported session migration: \(message)"
        case .changed(let message): "Session migration snapshot changed: \(message)"
        case .activeWriter(let pids): "Session files have active writers: \(pids.map(String.init).joined(separator: ", "))"
        case .desktopRunning: "Codex Desktop must be fully stopped before session migration."
        }
    }
}

public struct SessionProviderSynchronizer: Sendable {
    public let home: URL
    public let sqliteHome: URL
    public let backupRoot: URL
    public let catalogDatabases: [URL]
    private let checkpoint: @Sendable (SessionMigrationCheckpoint) throws -> Void
    private let availableSpace: @Sendable (URL) throws -> Int64

    public init(home: URL, sqliteHome: URL? = nil, catalogDatabases: [URL] = [], backupRoot: URL? = nil) {
        self.init(home: home, sqliteHome: sqliteHome, catalogDatabases: catalogDatabases, backupRoot: backupRoot, checkpoint: { _ in })
    }

    init(home: URL, sqliteHome: URL? = nil, catalogDatabases: [URL] = [], backupRoot: URL? = nil,
         availableSpace: (@Sendable (URL) throws -> Int64)? = nil,
         checkpoint: @escaping @Sendable (SessionMigrationCheckpoint) throws -> Void) {
        self.home = home.standardizedFileURL
        self.sqliteHome = (sqliteHome ?? home).standardizedFileURL
        self.backupRoot = (backupRoot ?? home.appendingPathComponent(".codex-account-menu-session-backups")).standardizedFileURL
        self.catalogDatabases = catalogDatabases.map(\.standardizedFileURL)
        self.checkpoint = checkpoint
        self.availableSpace = availableSpace ?? sessionAvailableSpace
    }

    /// Reads only routing columns, each thread's first own metadata record, and
    /// file sizes. It tolerates normal appends and unrelated SQLite row updates.
    public func estimate(targetProvider: String = "openai") throws -> SessionProviderEstimate {
        guard ["openai", "copilot"].contains(targetProvider) else { throw SessionProviderError.invalid("unknown target provider") }
        try validateRoots()
        let paths = try databasePaths()
        var rollouts: [UUID: URL] = [:]
        var references: [UUID: Set<URL>] = [:]
        var changed: Set<UUID> = []
        for path in paths {
            let db = try SessionSQLite(path: path, writable: false)
            defer { db.close() }
            guard try db.hasTable("threads") else { continue }
            try db.requireColumns("threads", ["id", "model_provider", "rollout_path"])
            for row in try db.query("SELECT id, model_provider, rollout_path FROM threads") {
                guard let text = row.text("id"), let id = UUID(uuidString: text) else {
                    throw SessionProviderError.invalid("threads.id is not a UUID in \(path.lastPathComponent)")
                }
                guard let provider = row.text("model_provider"), ["openai", "copilot"].contains(provider) else { continue }
                guard let rawPath = row.text("rollout_path"), !rawPath.isEmpty else {
                    throw SessionProviderError.invalid("missing rollout path for \(text)")
                }
                let rollout = URL(fileURLWithPath: rawPath, relativeTo: home).standardizedFileURL
                try validateRolloutPath(rollout)
                if let previous = rollouts[id], previous != rollout { throw SessionProviderError.invalid("multiple rollout paths for \(text)") }
                rollouts[id] = rollout
                references[id, default: []].insert(path)
                if provider != targetProvider { changed.insert(id) }
            }
        }
        var rewriteSizes: [UUID: Int64] = [:]
        for (id, rollout) in rollouts {
            let metadata = try firstSessionProvider(rollout, thread: id, requireStableFile: false)
            if metadata.provider != targetProvider {
                changed.insert(id)
                rewriteSizes[id] = Int64(metadata.identity.size)
            }
        }
        for path in paths {
            let db = try SessionSQLite(path: path, writable: false)
            defer { db.close() }
            guard try db.hasTable("local_thread_catalog") else { continue }
            try db.requireColumns("local_thread_catalog", ["host_id", "thread_id", "model_provider"])
            let localHosts = try db.localHosts()
            for row in try db.query("SELECT host_id, thread_id, model_provider FROM local_thread_catalog") {
                guard let text = row.text("thread_id"), let id = UUID(uuidString: text), rollouts[id] != nil,
                      let host = row.text("host_id"), localHosts.contains(host) else { continue }
                guard let provider = row.text("model_provider"), ["openai", "copilot"].contains(provider) else {
                    throw SessionProviderError.invalid("local catalog provider conflicts with selected thread \(text)")
                }
                if provider != targetProvider {
                    changed.insert(id)
                    references[id, default: []].insert(path)
                }
            }
        }
        let databases = changed.reduce(into: Set<URL>()) { $0.formUnion(references[$1] ?? []) }
        var bytes = changed.reduce(Int64(0)) { $0 + (rewriteSizes[$1] ?? 0) }
        for database in databases {
            try validateDatabasePath(database)
            guard let main = try SourceFileIdentity.read(database) else { throw SessionProviderError.changed(database.lastPathComponent) }
            bytes += Int64(main.size)
            if let wal = try SourceFileIdentity.read(URL(fileURLWithPath: database.path + "-wal")) { bytes += Int64(wal.size) }
        }
        return SessionProviderEstimate(threadCount: changed.count, backupBytesUpperBound: bytes)
    }

    /// Source transactions must stop native writers before changing credentials,
    /// config, or relay state, even when no session labels need migration.
    public func requireQuiescent(lock: SourceSwitchLock,
                                 desktopStopped: @Sendable () async throws -> Bool) async throws {
        try lock.requireHeld(for: home)
        guard try await desktopStopped() else { throw SessionProviderError.desktopRunning }
        try lock.requireHeld(for: home)
        try validateRoots()
        let databases = try databasePaths()
        var paths = databases.flatMap { path in
            [path] + ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: path.path + $0) }
        }
        for path in databases {
            let db = try SessionSQLite(path: path, writable: false)
            defer { db.close() }
            guard try db.hasTable("threads") else { continue }
            try db.requireColumns("threads", ["model_provider", "rollout_path"])
            for row in try db.query("SELECT model_provider, rollout_path FROM threads") {
                guard let source = row.text("model_provider"), ["openai", "copilot"].contains(source) else { continue }
                guard let rawPath = row.text("rollout_path"), !rawPath.isEmpty else {
                    throw SessionProviderError.invalid("missing rollout path during writer check")
                }
                let rollout = URL(fileURLWithPath: rawPath, relativeTo: home).standardizedFileURL
                try validateRolloutPath(rollout)
                paths.append(rollout)
            }
        }
        let writers = try sessionWriters(paths)
        if !writers.isEmpty { throw SessionProviderError.activeWriter(writers) }
    }

    /// nil selects only local rows whose provider is openai/copilot and differs
    /// from the target. Explicit IDs that cannot be located are rejected.
    /// Planning opens SQLite read-only and creates no backup or migration files.
    public func plan(threadIDs: Set<UUID>? = nil, targetProvider: String = "openai") throws -> SessionProviderPlan {
        guard ["openai", "copilot"].contains(targetProvider) else { throw SessionProviderError.invalid("unknown target provider") }
        try validateRoots()
        let paths = try databasePaths()
        var rowsByDatabase: [URL: [SessionDatabaseRow]] = [:]
        var schemas: [URL: String] = [:]
        var canonical: [UUID: URL] = [:]
        var localThreads: [UUID: URL] = [:]
        var references: [UUID: [(URL, SessionDatabaseRow)]] = [:]
        var checkedHeaders: [UUID: SessionUnchangedFile] = [:]
        var providers: [UUID: Set<String>] = [:]
        var found: Set<UUID> = []
        var skipped: [SessionProviderSkip] = []
        for path in paths {
            let db = try SessionSQLite(path: path, writable: false)
            let schema = try db.schema()
            schemas[path] = schema
            if try db.hasTable("threads") {
                try db.requireColumns("threads", ["id", "model_provider", "rollout_path"])
                for row in try db.query("SELECT * FROM threads") {
                    guard let idText = row.text("id"), let id = UUID(uuidString: idText) else {
                        throw SessionProviderError.invalid("threads.id is not a UUID in \(path.lastPathComponent)")
                    }
                    if let threadIDs, !threadIDs.contains(id) { continue }
                    found.insert(id)
                    guard let source = row.text("model_provider"), ["openai", "copilot"].contains(source) else {
                        skipped.append(.init(threadID: idText, reason: "provider is outside the openai/copilot scope")); continue
                    }
                    guard let rawPath = row.text("rollout_path"), !rawPath.isEmpty else {
                        throw SessionProviderError.invalid("missing rollout path for \(idText)")
                    }
                    let rollout = URL(fileURLWithPath: rawPath, relativeTo: home).standardizedFileURL
                    if let prior = localThreads[id], prior != rollout { throw SessionProviderError.invalid("multiple rollout paths for \(idText)") }
                    localThreads[id] = rollout
                    let reference = try SessionDatabaseRow(table: "threads", key: ["id": .text(idText)], row: row)
                    references[id, default: []].append((path, reference))
                    if source == targetProvider {
                        skipped.append(.init(threadID: idText, reason: "already uses the target provider")); continue
                    }
                    try validateRolloutPath(rollout)
                    if let prior = canonical[id], prior != rollout { throw SessionProviderError.invalid("multiple rollout paths for \(idText)") }
                    canonical[id] = rollout
                    providers[id, default: []].insert(source)
                    rowsByDatabase[path, default: []].append(reference)
                }
            }
            db.close()
        }
        if let threadIDs, !threadIDs.isSubset(of: found) { throw SessionProviderError.invalid("one or more explicitly selected threads were not found in local threads tables") }

        // The database is an index, not proof of the rollout's active provider.
        // Most files need only their first matching session_meta, not an 8 GiB
        // corpus hash, while mismatches receive the full streaming rewrite plan.
        for (id, rollout) in localThreads {
            try validateRolloutPath(rollout)
            let header = try firstSessionProvider(rollout, thread: id)
            checkedHeaders[id] = .init(url: rollout, identity: header.identity)
            if header.provider != targetProvider {
                canonical[id] = rollout
                providers[id, default: []].insert(header.provider)
                skipped.removeAll { $0.threadID.caseInsensitiveCompare(id.uuidString) == .orderedSame && $0.reason == "already uses the target provider" }
            }
        }

        for path in paths {
            let db = try SessionSQLite(path: path, writable: false)
            if try db.hasTable("local_thread_catalog") {
                try db.requireColumns("local_thread_catalog", ["host_id", "thread_id", "model_provider"])
                let localHosts = try db.localHosts()
                for row in try db.query("SELECT * FROM local_thread_catalog") {
                    guard let text = row.text("thread_id"), let id = UUID(uuidString: text), let rollout = localThreads[id] else { continue }
                    guard let host = row.text("host_id"), localHosts.contains(host) else {
                        skipped.append(.init(threadID: text, reason: "remote catalog host preserved")); continue
                    }
                    guard let source = row.text("model_provider"), ["openai", "copilot"].contains(source) else {
                        throw SessionProviderError.invalid("local catalog provider conflicts with selected thread \(text)")
                    }
                    if source != targetProvider {
                        try validateRolloutPath(rollout)
                        canonical[id] = rollout
                        providers[id, default: []].insert(source)
                        skipped.removeAll { $0.threadID.caseInsensitiveCompare(text) == .orderedSame && $0.reason == "already uses the target provider" }
                        rowsByDatabase[path, default: []].append(try SessionDatabaseRow(table: "local_thread_catalog", key: ["host_id": .text(host), "thread_id": .text(text)], row: row))
                    }
                }
            }
            db.close()
        }

        // A stale paginated index can be the sole changed row. Still lock and
        // compare its canonical thread row so it cannot change behind the plan.
        for id in canonical.keys {
            for (path, row) in references[id] ?? [] where row.previousProvider == targetProvider {
                rowsByDatabase[path, default: []].append(row)
            }
        }

        var filePlans: [SessionRolloutPlan] = []
        for id in canonical.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let path = canonical[id]!
            let scan = try scanRollout(path, thread: id, target: targetProvider, output: nil)
            guard scan.metadataCount > 0 else { throw SessionProviderError.invalid("no matching session_meta in \(path.lastPathComponent)") }
            filePlans.append(SessionRolloutPlan(thread: id, fingerprint: scan.original, expectedHash: scan.outputHash, replacements: scan.replacements))
        }
        var dbPlans: [SessionDatabasePlan] = []
        for path in rowsByDatabase.keys.sorted(by: { $0.path < $1.path }) {
            let db = try SessionSQLite(path: path, writable: false)
            guard try db.schema() == schemas[path] else { throw SessionProviderError.changed(path.lastPathComponent) }
            for row in rowsByDatabase[path]! { try db.requireRow(row, provider: row.previousProvider) }
            db.close()
            dbPlans.append(SessionDatabasePlan(path: path, schema: schemas[path]!, rows: rowsByDatabase[path]!,
                fingerprints: try databaseFingerprints(path)))
        }
        let threads = filePlans.map { file in
            SessionProviderThread(id: file.thread, rollout: file.fingerprint.url,
                previousProviders: Array(providers[file.thread] ?? []).sorted(), bytes: Int64(file.fingerprint.identity.size))
        }
        let rewrittenBytes = filePlans.filter { $0.replacements > 0 }.reduce(Int64(0)) { $0 + Int64($1.fingerprint.identity.size) }
        let databaseBytes = dbPlans.flatMap(\.fingerprints).reduce(Int64(0)) { $0 + Int64($1.identity.size) }
        return SessionProviderPlan(id: UUID(), home: home, targetProvider: targetProvider, threads: threads,
            skippedThreads: skipped, sqlitePaths: dbPlans.map(\.path), rolloutBytesToRewrite: rewrittenBytes,
            backupBytesUpperBound: rewrittenBytes + databaseBytes, databases: dbPlans, files: filePlans,
            unchangedFiles: checkedHeaders.filter { canonical[$0.key] == nil }.map(\.value), inspectedSQLitePaths: paths)
    }

    public func apply(_ plan: SessionProviderPlan, lock: SourceSwitchLock,
                      desktopStopped: @Sendable () async throws -> Bool) async throws -> SessionProviderReceipt {
        guard plan.home == home else { throw SessionProviderError.invalid("plan belongs to another home") }
        try await requirePermission(plan, lock: lock, desktopStopped: desktopStopped)
        for file in plan.unchangedFiles {
            try validateRolloutPath(file.url)
            guard try SourceFileIdentity.read(file.url) == file.identity else { throw SessionProviderError.changed(file.url.lastPathComponent) }
        }
        if plan.isEmpty { return SessionProviderReceipt(plan: plan, backupDirectory: nil, changedJSONLFiles: 0, changedSQLiteRows: 0, files: [], committedDatabases: []) }
        // Clones are an optimization, never a reason to assume zero backup cost.
        // Require enough space even for full-copy backups plus rewritten rollouts.
        for location in [home, backupRoot] {
            guard try availableSpace(location) >= plan.requiredFreeSpaceUpperBound else {
                throw SessionProviderError.invalid("insufficient free space; migration requires a conservative \(plan.requiredFreeSpaceUpperBound) bytes including a 64 MiB reserve")
            }
        }
        var backup: URL?
        var connections: [(SessionDatabasePlan, SessionSQLite)] = []
        var installed: [SessionInstalledFile] = []
        var committed: [URL] = []
        var uncertainWrites: [String] = []
        do {
            try validateRoots()
            for file in plan.files { try validateRolloutPath(file.fingerprint.url); try file.fingerprint.requireUnchanged() }
            for database in plan.databases {
                try requireDatabaseFingerprintSet(database)
                let db = try SessionSQLite(path: database.path, writable: true)
                do {
                    try db.execute("BEGIN IMMEDIATE")
                    guard try db.schema() == database.schema else { throw SessionProviderError.changed(database.path.lastPathComponent) }
                    for row in database.rows { try db.requireRow(row, provider: row.previousProvider) }
                    connections.append((database, db))
                } catch { try? db.execute("ROLLBACK"); db.close(); throw error }
            }
            let directory = backupRoot.appendingPathComponent(plan.id.uuidString)
            try createPrivateDirectory(directory)
            backup = directory
            for (index, database) in plan.databases.enumerated() {
                let folder = directory.appendingPathComponent("database-\(index)")
                try createPrivateDirectory(folder)
                for fingerprint in database.fingerprints {
                    try fingerprint.requireUnchanged()
                    try copyPrivate(fingerprint.url, to: folder.appendingPathComponent(fingerprint.url.lastPathComponent))
                }
            }
            try writeJournal(plan, directory: directory, phase: "prepared", installed: installed, committed: committed)
            for (index, file) in plan.files.enumerated() where file.replacements > 0 {
                try await requirePermission(plan, lock: lock, desktopStopped: desktopStopped, paths: [file.fingerprint.url])
                try validateRolloutPath(file.fingerprint.url)
                let saved = directory.appendingPathComponent("rollout-\(index).jsonl")
                try file.fingerprint.requireUnchanged()
                try copyPrivate(file.fingerprint.url, to: saved)
                guard try SessionFingerprint.read(saved).hash == file.fingerprint.hash else { throw SessionProviderError.changed(file.fingerprint.url.lastPathComponent) }
                let temporary = file.fingerprint.url.deletingLastPathComponent().appendingPathComponent(".session-provider-\(UUID()).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let out = try createPrivateFile(temporary)
                let scan: SessionRolloutScan
                do {
                    scan = try scanRollout(file.fingerprint.url, thread: file.thread, target: plan.targetProvider, output: out)
                    try out.synchronize(); try out.close()
                } catch { try? out.close(); throw error }
                guard scan.original == file.fingerprint, scan.outputHash == file.expectedHash,
                      scan.replacements == file.replacements else { throw SessionProviderError.changed(file.fingerprint.url.lastPathComponent) }
                try file.fingerprint.requireUnchanged()
                guard Darwin.rename(temporary.path, file.fingerprint.url.path) == 0 else { throw sessionPOSIXError() }
                uncertainWrites.append("Unverified rollout replacement: \(file.fingerprint.url.lastPathComponent)")
                let owned = try SessionFingerprint.read(file.fingerprint.url)
                guard owned.hash == file.expectedHash else { throw SessionProviderError.changed(file.fingerprint.url.lastPathComponent) }
                installed.append(.init(original: file.fingerprint, installed: owned, backup: saved))
                uncertainWrites.removeLast()
                try writeJournal(plan, directory: directory, phase: "writing", installed: installed, committed: committed)
                try checkpoint(.fileInstalled(file.fingerprint.url))
            }
            for (database, db) in connections {
                for row in database.rows {
                    try db.requireRow(row, provider: row.previousProvider)
                    if row.previousProvider != plan.targetProvider { try db.update(row, from: row.previousProvider, to: plan.targetProvider) }
                    try db.requireRow(row, provider: plan.targetProvider)
                }
            }
            for (database, db) in connections {
                try await requirePermission(plan, lock: lock, desktopStopped: desktopStopped)
                for file in plan.files {
                    if let owned = installed.first(where: { $0.original.url == file.fingerprint.url }) { try owned.installed.requireUnchanged() }
                    else { try file.fingerprint.requireUnchanged() }
                }
                for file in plan.unchangedFiles {
                    guard try SourceFileIdentity.read(file.url) == file.identity else { throw SessionProviderError.changed(file.url.lastPathComponent) }
                }
                try db.execute("COMMIT")
                committed.append(database.path)
                try writeJournal(plan, directory: directory, phase: "committing", installed: installed, committed: committed)
                try checkpoint(.databaseCommitted(database.path))
            }
            for (_, db) in connections { db.close() }
            try writeJournal(plan, directory: directory, phase: "complete", installed: installed, committed: committed)
            return SessionProviderReceipt(plan: plan, backupDirectory: directory,
                changedJSONLFiles: installed.count, changedSQLiteRows: plan.databases.reduce(0) { $0 + $1.rows.filter { $0.previousProvider != plan.targetProvider }.count },
                files: installed, committedDatabases: committed)
        } catch {
            for (_, db) in connections { try? db.execute("ROLLBACK"); db.close() }
            var errors = uncertainWrites
            do {
                try await requirePermission(plan, lock: lock, desktopStopped: desktopStopped)
                errors += restore(plan, files: installed, databases: committed)
            } catch { errors.append(error.localizedDescription) }
            if let backup { try? writeJournal(plan, directory: backup, phase: errors.isEmpty ? "rolledBack" : "recoveryRequired", installed: installed, committed: committed) }
            throw SessionProviderFailure(cause: error.localizedDescription, backupDirectory: backup, rollbackErrors: errors)
        }
    }

    public func rollback(_ receipt: SessionProviderReceipt, lock: SourceSwitchLock,
                         desktopStopped: @Sendable () async throws -> Bool) async throws {
        try await requirePermission(receipt.plan, lock: lock, desktopStopped: desktopStopped)
        let errors = restore(receipt.plan, files: receipt.files, databases: receipt.committedDatabases)
        if let directory = receipt.backupDirectory {
            try writeJournal(receipt.plan, directory: directory, phase: errors.isEmpty ? "rolledBack" : "recoveryRequired",
                installed: receipt.files, committed: receipt.committedDatabases)
        }
        if !errors.isEmpty { throw SessionProviderFailure(cause: "rollback could not safely restore every item", backupDirectory: receipt.backupDirectory, rollbackErrors: errors) }
    }

    private func restore(_ plan: SessionProviderPlan, files: [SessionInstalledFile], databases: [URL]) -> [String] {
        var errors: [String] = []
        for path in databases.reversed() {
            do {
                guard let saved = plan.databases.first(where: { $0.path == path }) else { throw SessionProviderError.invalid("missing database recovery plan") }
                try validateDatabasePath(path)
                let identity = try SourceFileIdentity.read(path)
                guard let original = saved.fingerprints.first(where: { $0.url == path }),
                      identity?.device == original.identity.device, identity?.inode == original.identity.inode else {
                    throw SessionProviderError.changed(path.lastPathComponent)
                }
                let db = try SessionSQLite(path: path, writable: true)
                defer { db.close() }
                try db.execute("BEGIN IMMEDIATE")
                do {
                    guard try db.schema() == saved.schema else { throw SessionProviderError.changed("SQLite schema") }
                    for row in saved.rows {
                        if try db.matches(row, provider: row.previousProvider) { continue }
                        if try db.matches(row, provider: plan.targetProvider) {
                            try db.update(row, from: plan.targetProvider, to: row.previousProvider)
                        } else { errors.append("External SQLite change preserved: \(row.threadID)") }
                    }
                    try db.execute("COMMIT")
                } catch { try? db.execute("ROLLBACK"); throw error }
            } catch { errors.append(error.localizedDescription) }
        }
        for file in files.reversed() {
            do {
                try validateRolloutPath(file.original.url)
                let current = try SessionFingerprint.read(file.original.url)
                if current.hash == file.original.hash { continue }
                guard current == file.installed else { throw SessionProviderError.changed("external rollout edit preserved: \(file.original.url.lastPathComponent)") }
                guard try SessionFingerprint.read(file.backup).hash == file.original.hash else { throw SessionProviderError.changed("rollout backup") }
                let temporary = file.original.url.deletingLastPathComponent().appendingPathComponent(".session-restore-\(UUID()).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try copyPrivate(file.backup, to: temporary)
                try current.requireUnchanged()
                guard Darwin.rename(temporary.path, file.original.url.path) == 0 else { throw sessionPOSIXError() }
                guard try SessionFingerprint.read(file.original.url).hash == file.original.hash else { throw SessionProviderError.changed("restored rollout") }
            } catch { errors.append(error.localizedDescription) }
        }
        return errors
    }

    private func requirePermission(_ plan: SessionProviderPlan, lock: SourceSwitchLock,
                                   desktopStopped: @Sendable () async throws -> Bool, paths selectedPaths: [URL]? = nil) async throws {
        guard plan.home == home else { throw SessionProviderError.invalid("plan belongs to another home") }
        try lock.requireHeld(for: home)
        guard try await desktopStopped() else { throw SessionProviderError.desktopRunning }
        try lock.requireHeld(for: home)
        let paths = selectedPaths ?? (plan.files.map { $0.fingerprint.url } + plan.unchangedFiles.map(\.url) + plan.inspectedSQLitePaths.flatMap { path in
            [path, URL(fileURLWithPath: path.path + "-wal"), URL(fileURLWithPath: path.path + "-shm")]
        })
        let writers = try sessionWriters(paths)
        if !writers.isEmpty { throw SessionProviderError.activeWriter(writers) }
    }

    private func validateRoots() throws {
        try requireSessionDirectory(home)
        try requireSessionDirectory(sqliteHome)
        guard sessionDescendant(sqliteHome, of: home, allowRoot: true) else { throw SessionProviderError.invalid("SQLite home must be explicitly within the selected Codex home") }
        if let raw = ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"], !raw.isEmpty,
           URL(fileURLWithPath: raw).standardizedFileURL != sqliteHome { throw SessionProviderError.invalid("CODEX_SQLITE_HOME differs from the selected SQLite scope") }
        let config = home.appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: config.path) {
            try requireSessionFile(config)
            let text = try String(contentsOf: config, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "(?m)^\\s*(?:sqlite_home|[\"']sqlite_home[\"'])\\s*=")
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                throw SessionProviderError.invalid("config.toml declares sqlite_home; resolve this configuration explicitly before migration")
            }
        }
    }

    private func databasePaths() throws -> [URL] {
        var result: [URL] = []
        // sqliteHome is an explicit scope, not a search root. A nested sqlite/
        // directory can contain an obsolete state_5 index with stale rollouts.
        for folder in [sqliteHome] where sessionPathExists(folder) {
            try requireSessionDirectory(folder)
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                guard item.lastPathComponent.hasPrefix("state_"), item.pathExtension == "sqlite" else { continue }
                guard item.lastPathComponent == "state_5.sqlite" else { throw SessionProviderError.invalid("unrecognized state database version") }
                try validateDatabasePath(item); result.append(item)
            }
        }
        // Catalog database locations are application-version specific. Callers
        // must provide verified locations; never probe unrelated SQLite stores.
        for path in catalogDatabases {
            try validateDatabasePath(path)
            let db = try SessionSQLite(path: path, writable: false)
            defer { db.close() }
            guard try db.hasTable("local_thread_catalog") else { throw SessionProviderError.invalid("explicit catalog database has no local_thread_catalog") }
            result.append(path)
        }
        return Array(Set(result)).sorted { $0.path < $1.path }
    }

    private func validateDatabasePath(_ path: URL) throws {
        guard sessionDescendant(path, of: sqliteHome) else { throw SessionProviderError.invalid("database is outside the selected SQLite scope") }
        try requireSessionParents(path, under: sqliteHome)
        try requireSessionFile(path)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: path.path + suffix)
            if sessionPathExists(sidecar) { try requireSessionFile(sidecar) }
        }
    }

    private func validateRolloutPath(_ path: URL) throws {
        let roots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        guard let root = roots.first(where: { sessionDescendant(path, of: $0) }), path.pathExtension == "jsonl" else {
            throw SessionProviderError.invalid("rollout is not inside this home's sessions or archived_sessions")
        }
        try requireSessionDirectory(root)
        try requireSessionParents(path, under: root)
        try requireSessionFile(path)
    }

    private func databaseFingerprints(_ path: URL) throws -> [SessionFingerprint] {
        try validateDatabasePath(path)
        return try [path, URL(fileURLWithPath: path.path + "-wal")].compactMap { url in
            sessionPathExists(url) ? try SessionFingerprint.read(url) : nil
        }
    }

    private func requireDatabaseFingerprintSet(_ database: SessionDatabasePlan) throws {
        guard try databaseFingerprints(database.path) == database.fingerprints else { throw SessionProviderError.changed(database.path.lastPathComponent) }
    }
}

enum SessionMigrationCheckpoint: Sendable { case fileInstalled(URL), databaseCommitted(URL) }
private struct SessionRolloutPlan: Sendable { let thread: UUID; let fingerprint: SessionFingerprint; let expectedHash: Data; let replacements: Int }
private struct SessionUnchangedFile: Sendable { let url: URL; let identity: SourceFileIdentity }
private struct SessionInstalledFile: Sendable { let original: SessionFingerprint; let installed: SessionFingerprint; let backup: URL }
private struct SessionDatabasePlan: Sendable { let path: URL; let schema: String; let rows: [SessionDatabaseRow]; let fingerprints: [SessionFingerprint] }

private struct SessionFingerprint: Equatable, Sendable {
    let url: URL
    let identity: SourceFileIdentity
    let hash: Data
    static func read(_ url: URL) throws -> SessionFingerprint {
        try requireSessionFile(url)
        guard let before = try SourceFileIdentity.read(url) else { throw SessionProviderError.changed(url.lastPathComponent) }
        let input = try sessionInput(url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty { hasher.update(data: bytes) }
        guard try SourceFileIdentity.read(url) == before else { throw SessionProviderError.changed(url.lastPathComponent) }
        return SessionFingerprint(url: url, identity: before, hash: Data(hasher.finalize()))
    }
    func requireUnchanged() throws {
        guard try Self.read(url) == self else { throw SessionProviderError.changed(url.lastPathComponent) }
    }
}

private struct SessionRolloutScan { let original: SessionFingerprint; let outputHash: Data; let metadataCount: Int; let replacements: Int }

private func firstSessionProvider(_ url: URL, thread: UUID, requireStableFile: Bool = true) throws -> (provider: String, identity: SourceFileIdentity) {
    try requireSessionFile(url)
    guard let before = try SourceFileIdentity.read(url) else { throw SessionProviderError.changed(url.lastPathComponent) }
    let input = try sessionInput(url)
    defer { try? input.close() }
    var buffer = Data()
    let marker = Data("\"session_meta\"".utf8)
    let regex = try NSRegularExpression(pattern: "(?<!\\\\)\"model_provider\"\\s*:\\s*\"([^\"\\\\]*)\"")
    func inspect(_ line: Data) throws -> String? {
        guard line.range(of: marker) != nil else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw SessionProviderError.invalid("invalid rollout record") }
        guard json["type"] as? String == "session_meta" else { return nil }
        guard let payload = json["payload"] as? [String: Any], let idText = payload["id"] as? String,
              let id = UUID(uuidString: idText) else { throw SessionProviderError.invalid("unknown session_meta schema") }
        guard id == thread else { return nil }
        guard let provider = payload["model_provider"] as? String, ["openai", "copilot"].contains(provider),
              let text = String(data: line, encoding: .utf8) else { throw SessionProviderError.invalid("unknown session_meta provider") }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text), String(text[range]) == provider else {
            throw SessionProviderError.invalid("ambiguous session_meta provider field")
        }
        let after = try SourceFileIdentity.read(url)
        if requireStableFile {
            guard after == before else { throw SessionProviderError.changed(url.lastPathComponent) }
        } else {
            guard after?.device == before.device, after?.inode == before.inode else { throw SessionProviderError.changed(url.lastPathComponent) }
        }
        return provider
    }
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: end) + 1
            if let provider = try inspect(Data(buffer.prefix(count))) { return (provider, before) }
            buffer.removeFirst(count)
        }
        guard buffer.count <= 64 * 1024 * 1024 else { throw SessionProviderError.invalid("rollout record exceeds the bounded 64 MiB scanner limit") }
    }
    if !buffer.isEmpty, let provider = try inspect(buffer) { return (provider, before) }
    throw SessionProviderError.invalid("no matching session_meta in \(url.lastPathComponent)")
}

private func scanRollout(_ url: URL, thread: UUID, target: String, output: FileHandle?) throws -> SessionRolloutScan {
    try requireSessionFile(url)
    guard let before = try SourceFileIdentity.read(url) else { throw SessionProviderError.changed(url.lastPathComponent) }
    let input = try sessionInput(url)
    defer { try? input.close() }
    var sourceHash = SHA256(), outputHash = SHA256(), buffer = Data()
    var metadataCount = 0, replacements = 0
    let marker = Data("\"session_meta\"".utf8)
    let regex = try NSRegularExpression(pattern: "(?<!\\\\)\"model_provider\"\\s*:\\s*\"([^\"\\\\]*)\"")
    func consume(_ line: Data) throws {
        sourceHash.update(data: line)
        var next = line
        if line.range(of: marker) != nil {
            guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw SessionProviderError.invalid("invalid rollout record") }
            if json["type"] as? String == "session_meta" {
                guard let payload = json["payload"] as? [String: Any], let idText = payload["id"] as? String,
                      let id = UUID(uuidString: idText) else { throw SessionProviderError.invalid("unknown session_meta schema") }
                if id == thread {
                    guard let provider = payload["model_provider"] as? String, ["openai", "copilot"].contains(provider),
                          let text = String(data: line, encoding: .utf8) else { throw SessionProviderError.invalid("unknown session_meta provider") }
                    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text), String(text[range]) == provider else {
                        throw SessionProviderError.invalid("ambiguous session_meta provider field")
                    }
                    metadataCount += 1
                    if provider != target {
                        let lower = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8)!)
                        let upper = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound.samePosition(in: text.utf8)!)
                        next.replaceSubrange(lower..<upper, with: target.utf8)
                        replacements += 1
                    }
                }
            }
        }
        outputHash.update(data: next)
        try output?.write(contentsOf: next)
    }
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: end) + 1
            try consume(Data(buffer.prefix(count)))
            buffer.removeFirst(count)
        }
        guard buffer.count <= 64 * 1024 * 1024 else { throw SessionProviderError.invalid("rollout record exceeds the bounded 64 MiB scanner limit") }
    }
    if !buffer.isEmpty { try consume(buffer) }
    guard try SourceFileIdentity.read(url) == before else { throw SessionProviderError.changed(url.lastPathComponent) }
    return SessionRolloutScan(original: .init(url: url, identity: before, hash: Data(sourceHash.finalize())),
        outputHash: Data(outputHash.finalize()), metadataCount: metadataCount, replacements: replacements)
}

private enum SessionSQLValue: Codable, Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String), blob(Data)
}
private struct SessionSQLRow: Codable, Equatable, Sendable {
    var values: [String: SessionSQLValue]
    func text(_ key: String) -> String? { if case .text(let value) = values[key] { return value }; return nil }
}
private struct SessionDatabaseRow: Codable, Sendable {
    let table: String
    let key: [String: SessionSQLValue]
    let original: SessionSQLRow
    let previousProvider: String
    var threadID: String { original.text("id") ?? original.text("thread_id") ?? "unknown" }
    init(table: String, key: [String: SessionSQLValue], row: SessionSQLRow) throws {
        guard let provider = row.text("model_provider") else { throw SessionProviderError.invalid("missing SQLite provider") }
        self.table = table; self.key = key; self.original = row; self.previousProvider = provider
    }
}

private final class SessionSQLite {
    private var connection: OpaquePointer?
    init(path: URL, writable: Bool) throws {
        try requireSessionFile(path)
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &connection, flags, nil) == SQLITE_OK else { close(); throw SessionProviderError.invalid("cannot open SQLite database \(path.lastPathComponent)") }
        sqlite3_busy_timeout(connection, 0)
        try execute("PRAGMA trusted_schema=OFF")
        if !writable { try execute("PRAGMA query_only=ON") }
    }
    func close() { if let connection { sqlite3_close_v2(connection); self.connection = nil } }
    deinit { close() }
    func execute(_ sql: String, _ arguments: [SessionSQLValue] = []) throws { _ = try query(sql, arguments) }
    func query(_ sql: String, _ arguments: [SessionSQLValue] = []) throws -> [SessionSQLRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, slot)
            case .integer(let number): status = sqlite3_bind_int64(statement, slot, number)
            case .real(let number): status = sqlite3_bind_double(statement, slot, number)
            case .text(let text): status = sqlite3_bind_text(statement, slot, text, -1, transient)
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, slot, $0.baseAddress, Int32($0.count), transient) }
            }
            guard status == SQLITE_OK else { throw databaseError() }
        }
        var rows: [SessionSQLRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw databaseError() }
            var values: [String: SessionSQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: count))
                default: values[name] = .null
                }
            }
            rows.append(.init(values: values))
        }
    }
    func hasTable(_ table: String) throws -> Bool { !(try query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(table)])).isEmpty }
    func requireColumns(_ table: String, _ required: Set<String>) throws {
        let columns = Set(try query("PRAGMA table_info(\(sessionQuote(table)))").compactMap { $0.text("name") })
        guard required.isSubset(of: columns) else { throw SessionProviderError.invalid("unknown \(table) schema") }
        if columns.contains("model_provider") {
            // Ask SQLite which trigger programs this exact column update would
            // invoke. INSERT and timestamp-only triggers in native state_5 are
            // inactive here; a provider UPDATE trigger remains unsupported.
            let program = try query("EXPLAIN UPDATE \(sessionQuote(table)) SET model_provider=model_provider WHERE 0")
            guard !program.contains(where: { $0.text("opcode") == "Program" }) else {
                throw SessionProviderError.invalid("provider updates would invoke unrecognized triggers on \(table)")
            }
        }
    }
    func schema() throws -> String {
        let rows = try query("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(rows), as: UTF8.self)
    }
    func localHosts() throws -> Set<String> {
        if try !hasTable("local_thread_catalog_hosts") { return ["local"] }
        try requireColumns("local_thread_catalog_hosts", ["host_id", "host_kind"])
        return Set(try query("SELECT host_id FROM local_thread_catalog_hosts WHERE lower(host_kind)='local'").compactMap { $0.text("host_id") })
    }
    func matches(_ row: SessionDatabaseRow, provider: String) throws -> Bool {
        let keys = row.key.keys.sorted()
        let sql = "SELECT * FROM \(sessionQuote(row.table)) WHERE " + keys.map { "\(sessionQuote($0)) IS ?" }.joined(separator: " AND ")
        let current = try query(sql, keys.map { row.key[$0]! })
        var expected = row.original; expected.values["model_provider"] = .text(provider)
        return current.count == 1 && current[0] == expected
    }
    func requireRow(_ row: SessionDatabaseRow, provider: String) throws {
        guard try matches(row, provider: provider) else { throw SessionProviderError.changed("SQLite row \(row.threadID)") }
    }
    func update(_ row: SessionDatabaseRow, from: String, to: String) throws {
        let keys = row.key.keys.sorted()
        let sql = "UPDATE \(sessionQuote(row.table)) SET model_provider=? WHERE " + keys.map { "\(sessionQuote($0)) IS ?" }.joined(separator: " AND ") + " AND model_provider=?"
        try execute(sql, [.text(to)] + keys.map { row.key[$0]! } + [.text(from)])
        guard sqlite3_changes(connection) == 1 else { throw SessionProviderError.changed("SQLite row \(row.threadID)") }
    }
    private func databaseError() -> Error { SessionProviderError.invalid("SQLite operation failed (\(sqlite3_errcode(connection)))") }
}

private func sessionQuote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
private func sessionPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
private func sessionDescendant(_ path: URL, of root: URL, allowRoot: Bool = false) -> Bool {
    let p = path.standardizedFileURL.path, r = root.standardizedFileURL.path
    return (allowRoot && p == r) || p.hasPrefix(r + "/")
}
private func requireSessionDirectory(_ path: URL) throws {
    var value = stat()
    guard Darwin.lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw SessionProviderError.invalid("unsafe directory \(path.lastPathComponent)") }
}
private func requireSessionFile(_ path: URL) throws {
    var value = stat()
    guard Darwin.lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
        throw SessionProviderError.invalid("unsafe or missing file \(path.lastPathComponent)")
    }
}
private func requireSessionParents(_ path: URL, under root: URL) throws {
    // macOS may spell the same trusted ancestor /var or /private/var. Match the
    // root directory itself by identity while lstat rejects every child symlink.
    var rootIdentity = stat()
    guard Darwin.lstat(root.path, &rootIdentity) == 0, rootIdentity.st_mode & S_IFMT == S_IFDIR else {
        throw SessionProviderError.invalid("unsafe selected root")
    }
    var current = (path.path as NSString).deletingLastPathComponent
    while true {
        var identity = stat()
        guard Darwin.lstat(current, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR else {
            throw SessionProviderError.invalid("unsafe parent directory")
        }
        if identity.st_dev == rootIdentity.st_dev && identity.st_ino == rootIdentity.st_ino { return }
        let parent = (current as NSString).deletingLastPathComponent
        guard parent != current else { throw SessionProviderError.invalid("path escapes selected root") }
        current = parent
    }
}
private func sessionInput(_ path: URL) throws -> FileHandle {
    let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw sessionPOSIXError() }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}
private func createPrivateFile(_ path: URL) throws -> FileHandle {
    let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw sessionPOSIXError() }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}
private func createPrivateDirectory(_ path: URL) throws {
    if FileManager.default.fileExists(atPath: path.path) { try requireSessionDirectory(path); return }
    try createPrivateDirectory(path.deletingLastPathComponent())
    guard Darwin.mkdir(path.path, 0o700) == 0 else { throw sessionPOSIXError() }
}
private func copyPrivate(_ source: URL, to destination: URL) throws {
    try requireSessionFile(source)
    if Darwin.clonefile(source.path, destination.path, 0) == 0 {
        guard Darwin.chmod(destination.path, 0o600) == 0 else { throw sessionPOSIXError() }
        return
    }
    let output = try createPrivateFile(destination)
    let input = try sessionInput(source)
    defer { try? input.close(); try? output.close() }
    while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty { try output.write(contentsOf: bytes) }
    try output.synchronize()
}
private func sessionWriters(_ paths: [URL]) throws -> [Int32] {
    let existing = Array(Set(paths.filter { FileManager.default.fileExists(atPath: $0.path) })).sorted { $0.path < $1.path }
    var writers: Set<Int32> = []
    for offset in stride(from: 0, to: existing.count, by: 128) {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-Fpa", "--"] + existing[offset..<min(offset + 128, existing.count)].map(\.path)
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard [0, 1].contains(task.terminationStatus) else { throw SessionProviderError.invalid("cannot inspect session writers") }
        var pid: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if let pid, pid != getpid(), line == "aw" || line == "au" { writers.insert(pid) }
        }
    }
    return writers.sorted()
}
private func writeJournal(_ plan: SessionProviderPlan, directory: URL, phase: String,
                          installed: [SessionInstalledFile], committed: [URL]) throws {
    struct Journal: Encodable {
        let id: UUID, target: String, phase: String
        let home: String
        let rows: [[SessionDatabaseRow]]
        let sqlitePaths: [String]
        let rollouts: [String]
        let backups: [String]
        let committedDatabases: [String]
    }
    let journal = Journal(id: plan.id, target: plan.targetProvider, phase: phase, home: plan.home.path,
        rows: plan.databases.map(\.rows), sqlitePaths: plan.sqlitePaths.map(\.path),
        rollouts: installed.map { $0.original.url.path }, backups: installed.map { $0.backup.path }, committedDatabases: committed.map(\.path))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    _ = try SourceFileSnapshot.read(directory.appendingPathComponent("journal.json")).replace(with: encoder.encode(journal))
}
private func sessionPathExists(_ path: URL) -> Bool { var value = stat(); return Darwin.lstat(path.path, &value) == 0 }
private func sessionAvailableSpace(_ path: URL) throws -> Int64 {
    var existing = path
    while !sessionPathExists(existing) {
        let parent = existing.deletingLastPathComponent()
        guard parent.path != existing.path else { throw SessionProviderError.invalid("cannot resolve backup filesystem") }
        existing = parent
    }
    try requireSessionDirectory(existing)
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: existing.path)
    guard let number = attributes[.systemFreeSize] as? NSNumber else { throw SessionProviderError.invalid("cannot determine available filesystem space") }
    return number.int64Value
}
