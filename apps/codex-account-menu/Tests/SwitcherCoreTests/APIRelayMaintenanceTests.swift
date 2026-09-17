import Foundation
import Testing
@testable import SwitcherCore

struct APIRelayMaintenanceTests {
    @Test func nativeRouteDoesNotStartOrEnableARelay() async throws {
        let f = try Fixture(managed: false)
        defer { f.clean() }
        let relay = MaintenanceRelay()
        let result = try await APIRelayMaintenance.run(home: f.home, storage: f.storage, relay: relay)
        #expect(result.action == "not-required")
        #expect(await relay.calls.isEmpty)
    }

    @Test func missingConfiguredRelayIsRecoveredWithoutReadingOAuthOrChangingConfig() async throws {
        let f = try Fixture(managed: true)
        defer { f.clean() }
        let auth = f.home.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(atPath: auth.path, withDestinationPath: "/nonexistent/synthetic-credential")
        let before = try Data(contentsOf: f.config)
        let relay = MaintenanceRelay()
        let result = try await APIRelayMaintenance.run(home: f.home, storage: f.storage, relay: relay)
        #expect(result.action == "recovered")
        #expect(await relay.calls == ["status", "start", "enable"])
        #expect(try Data(contentsOf: f.config) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: auth.path) == "/nonexistent/synthetic-credential")
    }

    @Test func healthyOlderRelayIsReusedAndUpgradeRemainsPending() async throws {
        let f = try Fixture(managed: true)
        defer { f.clean() }
        let relay = MaintenanceRelay(existing: true)
        let result = try await APIRelayMaintenance.run(home: f.home, storage: f.storage, relay: relay)
        #expect(result.action == "healthy")
        #expect(result.upgradePending)
        #expect(await relay.calls == ["status"])
    }

    @Test func pendingSourceSwitchPreventsAllRelayWork() async throws {
        let f = try Fixture(managed: true)
        defer { f.clean() }
        let pending = f.storage.appendingPathComponent("switch-pending.json")
        let bytes = try JSONEncoder().encode(SourceSwitchPendingRecord(home: f.home))
        try bytes.write(to: pending)
        let relay = MaintenanceRelay()
        await #expect(throws: SourceSwitchRecoveryError.pending) {
            _ = try await APIRelayMaintenance.run(home: f.home, storage: f.storage, relay: relay)
        }
        #expect(await relay.calls.isEmpty)
        #expect(try Data(contentsOf: pending) == bytes)
    }

    @Test func aDifferentBoundHomePreventsAllRelayWork() async throws {
        let f = try Fixture(managed: true)
        defer { f.clean() }
        _ = try await AccountStore(baseURL: f.storage, activeHomeURL: f.home).loadRegistry()
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data(contentsOf: f.config).write(to: other.appendingPathComponent("config.toml"))
        let relay = MaintenanceRelay()
        await #expect(throws: AccountStoreBindingError.differentHome) {
            _ = try await APIRelayMaintenance.run(home: other, storage: f.storage, relay: relay)
        }
        #expect(await relay.calls.isEmpty)
    }

    private struct Fixture {
        let root: URL, home: URL, storage: URL, config: URL
        init(managed: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-maintenance-\(UUID())")
            home = root.appendingPathComponent("home")
            storage = root.appendingPathComponent("store")
            config = home.appendingPathComponent("config.toml")
            for directory in [home, storage] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let text = managed
                ? "# codex-account-menu managed-route v1\nmodel_provider = \"openai\"\nopenai_base_url = \"http://127.0.0.1:4142/v1\"\n"
                : "model_provider = \"openai\"\n"
            try Data(text.utf8).write(to: config)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor MaintenanceRelay: APIRelayControlling {
    var calls: [String] = []
    private var running: Bool
    private var enabled: Bool
    init(existing: Bool = false) { running = existing; enabled = existing }
    func status() -> APIRelayStatus? { calls.append("status"); return running ? state() : nil }
    func ensureRunning() -> APIRelayStatus { calls.append("start"); running = true; return state() }
    func ensureRunningForSourceSwitch() -> APIRelayStatus { calls.append("upgrade"); return state() }
    func setEnabled(_ value: Bool) -> APIRelayStatus { calls.append(value ? "enable" : "disable"); enabled = value; return state() }
    private func state() -> APIRelayStatus {
        .init(protocolVersion: 1, pid: 1234, instanceId: "ea8d9d49-9369-49db-afc7-2c63d49b09c8",
              host: "127.0.0.1", port: 4142, baseURL: "http://127.0.0.1:4142/v1",
              enabled: enabled, activeRequests: 0, activeWebSockets: 0, testMode: false, upstreamPort: 4141)
    }
}
