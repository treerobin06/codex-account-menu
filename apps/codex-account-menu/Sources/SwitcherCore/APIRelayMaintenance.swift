import Foundation

public struct APIRelayMaintenanceResult: Codable, Sendable {
    public let action: String
    public let pid: Int32?
    public let transportVersion: Int?
    public let upgradePending: Bool
}

/// Recovery only: never quits Desktop, upgrades a running helper, reads OAuth,
/// switches sources, or removes a pending source transaction.
public enum APIRelayMaintenance {
    public static func run(home: URL, storage: URL,
                           relay supplied: (any APIRelayControlling)? = nil) async throws -> APIRelayMaintenanceResult {
        let lock = try SourceSwitchLock(home: home)
        defer { lock.release() }
        let recovery = SwitchRecoveryGuard(baseURL: storage, home: home)
        try recovery.requireSafeAutomaticWork()
        // Reuse the canonical store-binding checks, without credential readers.
        _ = try await AccountStore(baseURL: storage, activeHomeURL: home).loadRegistry()
        let provider = ProviderConfiguration(codexHome: home)
        let snapshot = try await provider.snapshot()
        let route = try await provider.readRoute()
        try snapshot.file.requireUnchanged()
        guard route.isManaged && route.apiEnabled else {
            return .init(action: "not-required", pid: nil, transportVersion: nil, upgradePending: false)
        }
        let relay = supplied ?? APIRelayController(storage: storage)
        let previous = try await relay.status()
        try recovery.requireSafeAutomaticWork()
        let running: APIRelayStatus
        if let previous { running = previous }
        else { running = try await relay.ensureRunning() }
        try snapshot.file.requireUnchanged()
        try recovery.requireSafeAutomaticWork()
        let verified: APIRelayStatus
        if running.enabled { verified = running }
        else { verified = try await relay.setEnabled(true) }
        try snapshot.file.requireUnchanged()
        return .init(action: previous == nil ? "recovered" : (running.enabled ? "healthy" : "enabled"),
                     pid: verified.pid, transportVersion: verified.transportVersion,
                     upgradePending: verified.transportVersion != 2)
    }
}
