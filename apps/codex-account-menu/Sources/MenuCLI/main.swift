import Foundation
import SwitcherCore

private struct IsolatedDesktop: DesktopControlling {
    func closeDesktop() async throws {}
    func reopenDesktop() async throws {}
    func isDesktopStopped() async throws -> Bool { true }
}

@main
struct MenuCLI {
    static func main() async {
        do { try await run() }
        catch { try? emit(["error": MenuBackend.safeError(error)]); exit(1) }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command != "--help", command != "help" else {
            print("""
            codex-menu status | list | account | runtime-auth | usage | copilot | import-current
            codex-menu switch copilot|ACCOUNT_UUID --restart [--identity ACCOUNT_UUID]
            codex-menu plan copilot|ACCOUNT_UUID [--identity ACCOUNT_UUID]
            codex-menu back --restart
            codex-menu maintain-relay   (recover the configured relay only; never quits Desktop)
            Options: --home PATH --state PATH --codex PATH
            Tests only: --isolated (requires temporary --home and --state; never quits Desktop)
            """)
            return
        }
        func option(_ name: String) throws -> String? {
            guard let index = args.firstIndex(of: name) else { return nil }
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw failure("Missing value for " + name) }
            return args[index + 1]
        }
        let user = FileManager.default.homeDirectoryForCurrentUser
        let home = URL(fileURLWithPath: try option("--home") ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? user.appending(path: ".codex").path)
        let storage = URL(fileURLWithPath: try option("--state") ?? user.appending(path: "Library/Application Support/Codex Account Menu").path)
        let binary = try option("--codex") ?? ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        let client = CodexClient(locator: .init(explicitURL: binary.map { URL(fileURLWithPath: $0) }), requestTimeout: .seconds(25), clientVersion: "0.1.0")
        let store = AccountStore(baseURL: storage, activeHomeURL: home)
        let provider = ProviderConfiguration(codexHome: home)
        let readLock: SourceSwitchLock?
        if ["switch", "copilot", "session-provider-sync", "plan", "back", "maintain-relay"].contains(command) { readLock = nil }
        else { readLock = try SourceSwitchLock(home: home) }
        defer { readLock?.release() }
        if ["account", "runtime-auth", "usage", "import-current"].contains(command) {
            try SwitchRecoveryGuard(baseURL: storage, home: home).requireSafeAutomaticWork()
        }
        switch command {
        case "maintain-relay":
            let result = try await APIRelayMaintenance.run(home: home, storage: storage)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        case "session-provider-sync":
            guard args.contains("--isolated"), try option("--home") != nil,
                  try option("--state") != nil, isTemporary(home), isTemporary(storage) else {
                throw failure("Session fixture sync requires --isolated with temporary --home and --state")
            }
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            let synchronizer = SessionProviderSynchronizer(home: home, backupRoot: storage.appending(path: "session-backups"))
            let plan = try synchronizer.plan()
            let receipt = try await synchronizer.apply(plan, lock: lock, desktopStopped: { true })
            try emit(["threadIDs": plan.threads.map { $0.id.uuidString },
                      "changedJSONLFiles": receipt.changedJSONLFiles,
                      "changedSQLiteRows": receipt.changedSQLiteRows,
                      "backupDirectory": receipt.backupDirectory?.path as Any? ?? NSNull()] as [String: Any])
        case "status":
            let registry = try await store.loadRegistry()
            let pending = try SwitchRecoveryGuard(baseURL: storage, home: home).pendingRecord()
            try emit(["provider": try await provider.readProvider(), "lastChatGPTAccountID": registry.activeAccountID?.uuidString ?? "", "accounts": registry.accounts.map(profileJSON), "recoveryPending": pending != nil] as [String: Any])
        case "list": try emit(try await store.loadRegistry().accounts.map(profileJSON))
        case "account":
            let identity = try await client.verifyIdentity(profileHome: home)
            try emit(["accountID": identity.accountID ?? "", "email": identity.email ?? "", "upstreamAuthorizationVerified": true] as [String: Any])
        case "runtime-auth":
            let auth = try await client.readEffectiveAuthStatus(profileHome: home)
            try emit(["provider": try await provider.readProvider(),
                      "authMethod": auth.authMethod as Any? ?? NSNull(),
                      "requiresOpenaiAuth": auth.requiresOpenaiAuth,
                      "accountID": auth.identity?.accountID as Any? ?? NSNull(),
                      "email": auth.identity?.email as Any? ?? NSNull(),
                      "tokenRequested": false, "modelCalls": 0] as [String: Any])
        case "usage":
            let reading = try await client.readAccountUsage(profileHome: home)
            let usage = reading.usage
            try emit(["accountID": reading.identity.accountID ?? "", "remainingPercent": usage.remainingPercent, "resetsAt": iso(usage.resetsAt), "fiveHourRemainingPercent": usage.fiveHourRemainingPercent as Any? ?? NSNull()] as [String: Any])
        case "copilot":
            let value = try await CopilotUsageService().fetch()
            print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        case "import-current":
            let identity = try await client.verifyIdentity(profileHome: home)
            try await store.registerActiveIdentity(identity)
            try emit(try await store.loadRegistry().accounts.map(profileJSON))
        case "switch", "plan", "back":
            if command != "back" {
                guard args.count >= 2, !args[1].hasPrefix("--") else { throw failure("Specify copilot or an account UUID") }
                if args[1] != "copilot", try option("--identity") != nil { throw failure("--identity applies only to Copilot") }
            }
            let isolated = args.contains("--isolated")
            let desktop: any DesktopControlling
            if isolated {
                guard try option("--home") != nil, try option("--state") != nil, isTemporary(home), isTemporary(storage) else { throw failure("Isolated tests require explicit temporary --home and --state paths") }
                desktop = IsolatedDesktop()
            } else {
                guard command == "plan" || args.contains("--restart") else { throw failure("Switching requires --restart; Codex will normally quit and reopen") }
                desktop = MacDesktopController()
            }
            let target: SourceTarget?
            if command == "back" {
                target = nil // The service resolves the previous pair under its switch lock.
            } else if args[1] == "copilot" {
                if let supplied = try option("--identity") {
                    guard let id = UUID(uuidString: supplied) else { throw failure("Invalid official identity UUID") }
                    target = .copilotWithIdentity(id)
                } else { target = .copilot }
            }
            else if let id = UUID(uuidString: args[1]) { target = .chatGPT(id) }
            else { throw failure("Unknown account UUID") }
            let relay: APIRelayController? = isolated ? nil : APIRelayController(storage: storage)
            let switcher = SourceSwitchService(store: store, codex: client, desktop: desktop, provider: provider,
                relay: relay, activityGuard: isolated ? nil : CodexActivityGuard(home: home))
            if command == "plan" {
                guard let target else { throw failure("Specify a source to preview") }
                let preview = try await switcher.preview(to: target)
                try emit(["sessionCount": preview.sessionCount, "backupBytesUpperBound": preview.backupBytesUpperBound,
                    "stableRouting": preview.stableRouting, "readOnly": true, "modifiesHistory": false] as [String: Any])
                return
            }
            let value: MenuSelection
            if let target { value = try await switcher.switchSource(to: target) }
            else { value = try await switcher.restorePreviousSelection() }
            try emit(["provider": value.provider, "accountID": value.accountID?.uuidString ?? "", "isolated": isolated] as [String: Any])
        default: throw failure("Unknown command: " + command)
        }
    }

    static func profileJSON(_ p: AccountProfile) -> [String: Any] {
        ["id": p.id.uuidString, "name": p.displayName, "email": p.email ?? "", "accountID": p.accountID ?? ""]
    }
    static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return [URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory].contains {
            path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func emit(_ value: Any) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]), as: UTF8.self))
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CodexAccountMenu.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
