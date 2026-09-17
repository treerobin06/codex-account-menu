import Foundation

enum AccountStoreBindingError: LocalizedError, Equatable {
    case differentHome
    case unboundExistingStore
    case invalidBinding

    var errorDescription: String? {
        switch self {
        case .differentHome:
            "此账号库属于另一个 Codex 配置目录。请为自定义 --home 指定独立的 --state；原账号库未改变。"
        case .unboundExistingStore:
            "已有账号库缺少配置目录归属记录，无法安全认领。请使用独立的空 --state，或核验旧库归属后迁移。"
        case .invalidBinding:
            "账号库的配置目录归属记录无效；请先检查 home-binding.json，不要删除记录后重试。"
        }
    }
}

/// A store has one active account and previous selection, so it belongs to one
/// canonical home. Exclusive publication also arbitrates different-home locks.
enum AccountStoreBinding {
    static let filename = "home-binding.json"
    private struct Record: Codable {
        let version: Int
        let home: String
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func ensure(base: URL, home: URL, allowExistingUnbound: Bool,
                       fileManager: FileManager = .default) throws {
        let expected = canonical(home).path
        let marker = base.appendingPathComponent(filename)
        let snapshot = try SourceFileSnapshot.read(marker)
        if let bytes = snapshot.data {
            try validate(bytes, expected: expected)
            try snapshot.requireUnchanged()
            return
        }
        if !allowExistingUnbound {
            // Only a genuinely empty custom store can be claimed implicitly.
            let children = try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            guard children.isEmpty else { throw AccountStoreBindingError.unboundExistingStore }
        }
        let bytes = try JSONEncoder().encode(Record(version: 1, home: expected))
        do {
            _ = try snapshot.replace(with: bytes)
        } catch {
            // A concurrent instance may have claimed the empty store. Accept
            // its record only if it proves the exact same binding.
            guard let installed = try SourceFileSnapshot.read(marker).data else { throw error }
            try validate(installed, expected: expected)
        }
    }

    static func requireExisting(base: URL, home: URL) throws {
        let snapshot = try SourceFileSnapshot.read(base.appendingPathComponent(filename))
        guard let bytes = snapshot.data else { throw AccountStoreBindingError.unboundExistingStore }
        try validate(bytes, expected: canonical(home).path)
        try snapshot.requireUnchanged()
    }

    private static func validate(_ bytes: Data, expected: String) throws {
        guard let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.version == 1, record.home.hasPrefix("/"),
              canonical(URL(fileURLWithPath: record.home)).path == record.home else {
            throw AccountStoreBindingError.invalidBinding
        }
        guard record.home == expected else { throw AccountStoreBindingError.differentHome }
    }
}
