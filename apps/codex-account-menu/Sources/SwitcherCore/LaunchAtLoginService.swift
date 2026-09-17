import AppKit
import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unavailable
}

@MainActor
public protocol LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) async throws
    func openSystemSettings()
}

/// System status is the only source of truth; approval is distinct from enabled.
@MainActor
public final class LaunchAtLoginService: LaunchAtLoginManaging {
    private let adapter: (any LaunchAtLoginSystemAdapting)?
    private var updating = false

    public init() {
        adapter = LaunchAtLoginHost.current.isSupported ? MainAppLoginItemAdapter() : nil
    }

    init(adapter: any LaunchAtLoginSystemAdapting, host: LaunchAtLoginHost) {
        self.adapter = host.isSupported ? adapter : nil
    }

    public var status: LaunchAtLoginStatus { adapter?.status ?? .unavailable }

    public func setEnabled(_ enabled: Bool) async throws {
        guard let adapter else { throw LaunchAtLoginError.unavailable }
        guard !updating else { throw LaunchAtLoginError.busy }
        updating = true
        defer { updating = false }
        let current = adapter.status
        switch current {
        case .unavailable: throw LaunchAtLoginError.unavailable
        case .notFound:
            // A fresh main app may not have a system record yet. Registration
            // still validates its bundle/signature and must report a real status.
            guard enabled else { throw LaunchAtLoginError.notFound }
        case .notRegistered, .enabled, .requiresApproval: break
        }
        if enabled {
            // Already registered, including a registration awaiting user consent.
            guard current == .notRegistered || current == .notFound else { return }
            try adapter.register()
            guard [.enabled, .requiresApproval].contains(adapter.status) else {
                throw LaunchAtLoginError.changeNotApplied
            }
        } else {
            guard current != .notRegistered else { return }
            try await adapter.unregister()
            guard adapter.status == .notRegistered else { throw LaunchAtLoginError.changeNotApplied }
        }
    }

    public func openSystemSettings() { adapter?.openSystemSettings() }
}

enum LaunchAtLoginError: LocalizedError {
    case unavailable, notFound, busy, changeNotApplied
    var errorDescription: String? {
        switch self {
        case .unavailable: "登录时自动启动仅可在正式应用中设置。"
        case .notFound: "系统未找到此应用的登录项，请从安装位置重新打开应用。"
        case .busy: "登录项正在更新，请稍后重试。"
        case .changeNotApplied: "系统尚未确认登录项更改，请检查系统设置。"
        }
    }
}

/// Match the actual process executable as well as the bundle, so the embedded
/// CLI, unbundled SwiftPM products, tests and demo mode cannot register an item.
struct LaunchAtLoginHost: Sendable {
    var bundleURL: URL
    var bundleIdentifier: String?
    var packageType: String?
    var declaredExecutable: String?
    var executableURL: URL?
    var isDemoBundle: Bool?
    var isDemoMode: Bool

    var isSupported: Bool {
        guard bundleURL.pathExtension == "app", bundleIdentifier == "com.tree.codex-account-menu",
              packageType == "APPL", declaredExecutable == "CodexAccountMenu",
              isDemoBundle == false, !isDemoMode, let executableURL else { return false }
        let expected = bundleURL.appending(path: "Contents/MacOS/CodexAccountMenu")
        return executableURL.resolvingSymlinksInPath().standardizedFileURL ==
            expected.resolvingSymlinksInPath().standardizedFileURL
    }

    @MainActor static var current: Self {
        let bundle = Bundle.main
        return Self(bundleURL: bundle.bundleURL, bundleIdentifier: bundle.bundleIdentifier,
            packageType: bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
            declaredExecutable: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            executableURL: NSRunningApplication.current.executableURL,
            isDemoBundle: bundle.object(forInfoDictionaryKey: "CodexAccountMenuDemo") as? Bool,
            isDemoMode: CommandLine.arguments.contains("--demo"))
    }
}

@MainActor
protocol LaunchAtLoginSystemAdapting {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
private final class MainAppLoginItemAdapter: LaunchAtLoginSystemAdapting {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }

    func register() throws { try service.register() }
    // mainApp unregisters future login launches; it does not terminate this app.
    func unregister() async throws { try await service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
