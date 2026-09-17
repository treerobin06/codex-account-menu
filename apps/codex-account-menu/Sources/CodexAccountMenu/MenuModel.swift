import AppKit
import Combine
import Foundation
import SwitcherCore

@MainActor
final class MenuModel: ObservableObject {
    static let shared = MenuModel()

    let backend: MenuBackend
    let isDemo: Bool
    @Published private(set) var isStarting = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isQuitting = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .unavailable
    @Published private(set) var isUpdatingLoginItem = false
    @Published private(set) var loginItemError: String?
    private let loginItem: any LaunchAtLoginManaging = LaunchAtLoginService()
    private var failedLoginItemTarget: Bool?
    private var startup: Task<Void, Never>?
    private var visibleActivityPanels: Set<ObjectIdentifier> = []
    private var activityPolling: Task<Void, Never>?

    init() {
        // A disposable UI-test bundle stays in memory-only demo mode even if
        // Launch Services or an accessibility tool relaunches it without args.
        isDemo = CommandLine.arguments.contains("--demo")
            || Bundle.main.object(forInfoDictionaryKey: "CodexAccountMenuDemo") as? Bool == true
        backend = isDemo ? MenuBackend.demo() : MenuBackend()
        backend.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    var isBusy: Bool { isStarting || isQuitting || isUpdatingLoginItem || backend.isBusy || backend.isAddingAccount }
    var isCopilot: Bool { backend.selection.provider == "copilot" }
    var isChatGPT: Bool { backend.selection.provider == "openai" }

    var officialIdentityName: String {
        if let id = backend.officialIdentityAccountID,
           let profile = backend.accounts.first(where: { $0.id == id }) { return profile.displayName }
        return isStarting || backend.officialIdentityError == "正在核验当前配置" ? "正在核验…" : "未连接"
    }

    var canConnectCurrentIdentity: Bool {
        isCopilot && backend.selection.accountID != nil && backend.officialIdentityAccountID == nil
    }

    var currentName: String {
        if isCopilot { return "GitHub Copilot" }
        guard isChatGPT else {
            return backend.selection.provider.isEmpty ? "未知来源" : "其他来源 · \(backend.selection.provider)"
        }
        if let profile = backend.accounts.first(where: { $0.id == backend.selection.accountID }) {
            return profile.displayName
        }
        return "ChatGPT · 尚未导入"
    }

    var previousName: String? {
        guard let selection = backend.previousSelection else { return nil }
        if selection.provider == "copilot" {
            if selection.officialIdentityDisabled { return "Copilot／官方未连接" }
            let identity = backend.accounts.first(where: { $0.id == selection.accountID })?.displayName ?? "身份未记录"
            return "Copilot ＋ \(identity)"
        }
        guard selection.provider == "openai" else { return nil }
        return backend.accounts.first(where: { $0.id == selection.accountID })?.displayName
    }

    func isSelected(_ account: AccountProfile) -> Bool {
        isChatGPT && backend.selection.accountID == account.id
    }

    func start() async {
        if startup == nil {
            refreshLoginItemStatus()
            startup = Task { await backend.start() }
        }
        await startup?.value
        isStarting = false
    }

    func panelOpened() async {
        async let activity: Void = backend.refreshActivitySummary()
        await start()
        await refresh()
        await activity
    }

    func setActivityPanelVisible(_ window: NSWindow, visible: Bool) {
        let id = ObjectIdentifier(window)
        if visible { visibleActivityPanels.insert(id) }
        else { visibleActivityPanels.remove(id) }
        guard !visibleActivityPanels.isEmpty, !isQuitting else {
            activityPolling?.cancel(); activityPolling = nil
            return
        }
        guard activityPolling == nil else { return }
        activityPolling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.visibleActivityPanels.isEmpty, !self.isQuitting else { return }
                if !self.backend.isBusy && !self.backend.isAddingAccount {
                    await self.backend.refreshActivitySummary()
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    func refresh(force: Bool = false) async {
        refreshLoginItemStatus()
        guard !isRefreshing, !isBusy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await backend.refresh(force: force)
    }

    private func refreshLoginItemStatus() {
        launchAtLoginStatus = isDemo ? .unavailable : loginItem.status
        if let target = failedLoginItemTarget,
           (target && launchAtLoginStatus == .enabled) || (!target && launchAtLoginStatus == .notRegistered) {
            loginItemError = nil
            failedLoginItemTarget = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo, !isBusy else { return }
        isUpdatingLoginItem = true
        loginItemError = nil
        failedLoginItemTarget = nil
        Task {
            defer {
                refreshLoginItemStatus()
                isUpdatingLoginItem = false
            }
            do { try await loginItem.setEnabled(enabled) }
            catch {
                failedLoginItemTarget = enabled
                loginItemError = "自启动设置未完成：" + MenuBackend.safeError(error)
            }
        }
    }

    func openLoginItemSettings() {
        guard !isDemo else { return }
        loginItem.openSystemSettings()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func prepareToQuit() async -> Bool {
        guard !isBusy else { return false }
        isQuitting = true
        activityPolling?.cancel(); activityPolling = nil
        let ready = await backend.prepareToQuit()
        if !ready { isQuitting = false }
        return ready
    }
}
