import Foundation

/// A restart-safe warning, not a second source/credential journal. Recovery
/// still belongs to an explicitly requested SourceSwitchService transaction.
public struct SourceSwitchPendingRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let transactionID: UUID
    public let canonicalHome: String
    public let startedAt: Date

    public init(home: URL, transactionID: UUID = UUID(), startedAt: Date = Date()) {
        version = 1
        self.transactionID = transactionID
        canonicalHome = AccountStoreBinding.canonical(home).path
        self.startedAt = startedAt
    }
}

public enum SourceSwitchRecoveryError: LocalizedError, Sendable {
    case pending
    case invalidRecord
    case differentHome

    public var errorDescription: String? {
        switch self {
        case .pending:
            "上次来源切换未确认完成，已暂停自动读取和导入账号。请先明确选择要使用的来源与账号，完成正常切换后再恢复。"
        case .invalidRecord:
            "来源切换保护记录无效；请检查私有状态目录中的 switch-pending.json，暂不自动读取或导入账号。"
        case .differentHome:
            "来源切换保护记录属于另一个 Codex 配置目录；原记录保持不变。"
        }
    }
}

/// Injectable, read-only startup gate. Reading does not create directories,
/// claim a store, refresh OAuth, or remove a previous transaction's record.
public protocol SourceSwitchRecoveryChecking: Sendable {
    func pendingRecord() throws -> SourceSwitchPendingRecord?
    func requireSafeAutomaticWork() throws
}

public extension SourceSwitchRecoveryChecking {
    func requireSafeAutomaticWork() throws {
        if try pendingRecord() != nil { throw SourceSwitchRecoveryError.pending }
    }
}

public struct SwitchRecoveryGuard: SourceSwitchRecoveryChecking, Sendable {
    public let baseURL: URL
    public let home: URL
    public var recordURL: URL { baseURL.appendingPathComponent("switch-pending.json") }

    public init(baseURL: URL, home: URL) {
        self.baseURL = baseURL.standardizedFileURL
        self.home = AccountStoreBinding.canonical(home)
    }

    public func pendingRecord() throws -> SourceSwitchPendingRecord? {
        let checkpoint = try readCheckpoint()
        try checkpoint.file.requireUnchanged()
        return checkpoint.record
    }

    func prepare(lock: SourceSwitchLock) throws -> SwitchRecoveryCheckpoint {
        try lock.requireHeld(for: home)
        return try readCheckpoint()
    }

    /// Publish immediately before the first possible source side effect. A
    /// prior pending record is inherited verbatim and only a successful new
    /// explicit selection may remove it; rolling back the new attempt cannot.
    func begin(_ checkpoint: SwitchRecoveryCheckpoint, lock: SourceSwitchLock) throws -> SwitchRecoveryTransaction {
        try lock.requireHeld(for: home)
        guard checkpoint.file.url == recordURL else { throw SourceSwitchRecoveryError.invalidRecord }
        try checkpoint.file.requireUnchanged()
        if checkpoint.record != nil {
            return SwitchRecoveryTransaction(file: checkpoint.file, inheritedPending: true)
        }
        let data = try JSONEncoder().encode(SourceSwitchPendingRecord(home: home))
        let installed = try checkpoint.file.replace(with: data)
        return SwitchRecoveryTransaction(file: installed, inheritedPending: false)
    }

    func complete(_ transaction: SwitchRecoveryTransaction, recoveredPreviousState: Bool,
                  lock: SourceSwitchLock) throws {
        try lock.requireHeld(for: home)
        guard transaction.file.url == recordURL else { throw SourceSwitchRecoveryError.invalidRecord }
        if recoveredPreviousState && transaction.inheritedPending { return }
        // The exact snapshot prevents a late callback from clearing a newer
        // transaction, even when another writer has reused the same path.
        _ = try transaction.file.replace(with: nil)
    }

    private func readCheckpoint() throws -> SwitchRecoveryCheckpoint {
        if FileManager.default.fileExists(atPath: baseURL.path) {
            let values = try baseURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SourceFileError.unsafe("source switch state directory")
            }
        }
        let snapshot = try SourceFileSnapshot.read(recordURL)
        guard let data = snapshot.data else { return SwitchRecoveryCheckpoint(file: snapshot, record: nil) }
        guard let record = try? JSONDecoder().decode(SourceSwitchPendingRecord.self, from: data),
              record.version == 1, record.canonicalHome.hasPrefix("/"),
              record.startedAt.timeIntervalSinceReferenceDate.isFinite,
              AccountStoreBinding.canonical(URL(fileURLWithPath: record.canonicalHome)).path == record.canonicalHome else {
            throw SourceSwitchRecoveryError.invalidRecord
        }
        guard record.canonicalHome == home.path else { throw SourceSwitchRecoveryError.differentHome }
        return SwitchRecoveryCheckpoint(file: snapshot, record: record)
    }
}

struct SwitchRecoveryCheckpoint: Sendable {
    let file: SourceFileSnapshot
    let record: SourceSwitchPendingRecord?
}

struct SwitchRecoveryTransaction: Sendable {
    let file: SourceFileSnapshot
    let inheritedPending: Bool
}
