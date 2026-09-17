import AppKit
import SwiftUI
import SwitcherCore

struct AccountMenuView: View {
    @ObservedObject var model: MenuModel
    var onHeightChanged: ((CGFloat) -> Void)?
    @State private var pendingAction: PendingAction?
    @State private var editedName = ""
    @State private var contentHeight: CGFloat = 360
    @State private var previewText = "正在检查切换条件…"
    @State private var previewKey: String?
    @State private var previewFailed = false
    @State private var hostingWindow: NSWindow?
    @FocusState private var isNameFocused: Bool

    private var actionsDisabled: Bool { model.isBusy || pendingAction != nil }
    private var canEnableActivityRecording: Bool {
        guard model.isCopilot, let relay = model.backend.activitySummary.relay else { return false }
        return relay.observationVersion == nil
    }
    // Leave room for the activity card and the existing confirmation/footer.
    private var maximumListHeight: CGFloat {
        (pendingAction == nil ? 390 : 190) - (canEnableActivityRecording ? 30 : 0)
    }

    var body: some View {
        let activity = model.backend.activitySummary
        VStack(alignment: .leading, spacing: 12) {
            header

            APIActivitySummaryCard(summary: activity) {
                MenuAppDelegate.shared?.showActivityWindow(selecting: activity.latest?.threadUUID,
                    allowAutomaticSelection: activity.latest == nil)
            }
            if canEnableActivityRecording {
                HStack(spacing: 8) {
                    Button("启用记录…") { pendingAction = .enableRecording }
                        .buttonStyle(.borderless)
                        .disabled(actionsDisabled)
                        .help("进入现有切换确认；确认后正常退出并重开 Codex，再启用逐对话记录")
                    Text("会正常重开 Codex")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
            }

            if let pendingAction {
                confirmation(for: pendingAction)
            }

            if let error = model.backend.errorMessage, !error.isEmpty {
                errorNotice(error, dismiss: { model.backend.dismissError() })
            }
            if let error = model.backend.relayError { errorNotice(error) }

            if model.backend.isAddingAccount {
                loginNotice
            }

            ScrollView(.vertical) {
                accountList
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                        .allowsHitTesting(false)
                    }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(contentHeight, maximumListHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = max(1, $0.rounded(.up)) }

            footer
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Rectangle().fill(.regularMaterial).allowsHitTesting(false)
        }
        .background(AccountPanelWindowReader(window: $hostingWindow).allowsHitTesting(false))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            }
            .allowsHitTesting(false)
        }
        .onPreferenceChange(PanelHeightKey.self) { onHeightChanged?($0) }
        .task {
            updateActivityVisibility()
            await model.panelOpened()
        }
        .onChange(of: hostingWindow) { oldWindow, newWindow in
            if let oldWindow { model.setActivityPanelVisible(oldWindow, visible: false) }
            if let newWindow { updateActivityVisibility(newWindow) }
        }
        .onDisappear {
            if let hostingWindow { model.setActivityPanelVisible(hostingWindow, visible: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === hostingWindow else { return }
            updateActivityVisibility(window)
            Task { await model.panelOpened() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === hostingWindow else { return }
            updateActivityVisibility(window)
            guard window.isVisible, window.occlusionState.contains(.visible) else { return }
            Task { await model.panelOpened() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === hostingWindow else { return }
            model.setActivityPanelVisible(window, visible: false)
        }
    }

    private func updateActivityVisibility(_ window: NSWindow? = nil) {
        guard let window = window ?? hostingWindow else { return }
        model.setActivityPanelVisible(window, visible: window.isVisible && window.occlusionState.contains(.visible))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Codex 账号")
                        .font(.system(size: 16, weight: .semibold))
                    if model.isDemo {
                        Text("演示")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                Capsule().fill(.quaternary).allowsHitTesting(false)
                            }
                    }
                }
                Text("推理来源 · \(model.currentName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.currentName)
                Text("官方身份 · \(model.officialIdentityName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.backend.officialIdentityError ?? "当前配置的运行时身份；浏览器和 Remote 是否可用须分别验证")
            }
            Spacer(minLength: 0)
            if model.isBusy || model.isRefreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(model.isBusy ? "处理中…" : "读取额度…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.isBusy ? "正在处理" : "正在读取额度")
            } else {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(actionsDisabled)
                .help("刷新所有额度")
                .accessibilityLabel("刷新所有额度")
            }
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ChatGPT")

            if model.backend.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有保存的 ChatGPT 账号")
                        .font(.system(size: 12, weight: .medium))
                    Text("添加账号，或导入 Codex 当前登录的账号。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.025))
                        .allowsHitTesting(false)
                }
            }

            ForEach(model.backend.accounts) { account in
                chatGPTAccount(account)
            }

            sectionTitle("GitHub Copilot")
                .padding(.top, 6)
            copilotAccount
        }
        .padding(.trailing, 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func chatGPTAccount(_ account: AccountProfile) -> some View {
        SourceRow(
            name: account.displayName,
            subtitle: account.email,
            symbol: "person.crop.circle",
            selected: model.isSelected(account),
            disabled: actionsDisabled,
            select: { pendingAction = .chatGPT(account) },
            allowReselect: true,
            accessory: AnyView(accountOptions(account)),
            helpText: quotaHelp(model.backend.usageStates[account.id] ?? .idle)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                accountUsage(model.backend.usageStates[account.id] ?? .idle)
            }
        }
    }

    private func quotaHelp(_ state: UsageViewState) -> String? {
        switch state {
        case .stale(_, let error): return "显示上次获取的额度。\n" + error
        case .unavailable(let error): return error
        default: return nil
        }
    }

    private func accountOptions(_ account: AccountProfile) -> some View {
        Menu {
            Button("重命名…") {
                editedName = account.displayName
                pendingAction = .rename(account)
            }
            Button("移除本地记录…", role: .destructive) {
                pendingAction = .remove(account)
            }
            .disabled(model.backend.selection.accountID == account.id)
        } label: {
            Image(systemName: "ellipsis").frame(width: 18, height: 15)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(actionsDisabled)
        .accessibilityLabel("管理账号 \(account.displayName)")
        .help(model.backend.selection.accountID == account.id ? "重命名；先切换到其他 ChatGPT 账号，才可移除此登录副本" : "重命名或移除本地记录")
    }

    @ViewBuilder
    private func accountUsage(_ state: UsageViewState) -> some View {
        if let usage = state.displayedUsage {
            UsageMeter(title: "周额度剩余", percent: Double(usage.remainingPercent), resetsAt: usage.resetsAt)
            if let remaining = usage.fiveHourRemainingPercent {
                UsageMeter(title: "5小时额度剩余", percent: Double(remaining), resetsAt: usage.fiveHourResetsAt)
            }
            if let error = state.refreshError {
                SmallNotice(text: "显示上次额度。\(error)", warning: true)
            }
        } else {
            switch state {
            case .idle:
                SmallNotice(text: model.isBusy ? "正在读取额度…" : "额度尚未获取")
            case let .unavailable(message):
                SmallNotice(text: message, warning: true)
            default:
                EmptyView()
            }
        }
    }

    private var copilotAccount: some View {
        SourceRow(
            name: "GitHub Copilot",
            subtitle: model.backend.copilotSnapshot?.login,
            symbol: "chevron.left.forwardslash.chevron.right",
            selected: model.isCopilot,
            disabled: actionsDisabled,
            select: {
                pendingAction = .copilot
            },
            allowReselect: true,
            accessory: AnyView(copilotIdentityOptions),
            helpText: [model.backend.officialIdentityError, model.backend.copilotError]
                .compactMap { $0 }.joined(separator: "\n\n")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("官方身份：\(model.officialIdentityName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(model.backend.officialIdentityError ?? (model.isCopilot ? "推理使用 Copilot；官方身份用于原生功能" : "选择此来源后，推理使用 Copilot，并保留官方身份"))
                if let snapshot = model.backend.copilotSnapshot {
                    if let remaining = snapshot.remainingPercent {
                        UsageMeter(title: "本期剩余 · 快照", percent: remaining, resetsAt: snapshot.resetsAt)
                    } else {
                        SmallNotice(text: "本期额度未提供剩余百分比")
                        if let resetsAt = snapshot.resetsAt {
                            Text("重置于 \(MenuDate.display(resetsAt))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if !snapshot.plan.isEmpty { Text(MenuText.copilotPlan(snapshot.plan)) }
                            if snapshot.tokenBasedBilling { Text("· 按用量计费") }
                            if snapshot.overagePermitted { Text("· 允许超额") }
                        }
                        Text("获取于 \(MenuDate.display(snapshot.observedAt))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                } else if model.backend.copilotError == nil {
                    SmallNotice(text: "尚无本期用量快照")
                }
                if let error = model.backend.copilotError {
                    SmallNotice(text: error, warning: true)
                }
            }
        }
    }

    private var copilotIdentityOptions: some View {
        Menu {
            ForEach(model.backend.accounts) { account in
                Button("使用官方身份：\(account.displayName)") {
                    pendingAction = .copilotIdentity(account)
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 18, height: 15)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(actionsDisabled || model.backend.accounts.isEmpty)
        .accessibilityLabel("选择 Copilot 的官方身份")
        .help("选择一个已保存账号，一次重启同时设置 Copilot 和官方身份")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    Task { await model.backend.addAccount() }
                } label: {
                    Label("添加 ChatGPT 账号…", systemImage: "plus")
                }
                .disabled(actionsDisabled)
                .help("使用 OpenAI 官方浏览器登录，添加后可从列表切换")
                Spacer(minLength: 0)
                Button("导入当前登录") {
                    Task { await model.backend.importCurrentAccount() }
                }
                .disabled(actionsDisabled)
                .help("保存 Codex 当前的 ChatGPT 登录，方便以后切回")
            }
            .font(.system(size: 11))
            .controlSize(.small)

            launchAtLogin

            if !model.backend.status.isEmpty {
                Text(model.backend.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(model.backend.status)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline) {
                if let name = model.previousName {
                    Button {
                        pendingAction = .previous(name)
                    } label: {
                        Label("切回上次", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(actionsDisabled)
                    .help("切回 \(name)，将正常退出并重新打开 Codex")
                }
                Spacer()
                Button("退出小工具") { model.quit() }
                    .disabled(model.isBusy)
                    .help("只退出账号小工具，Codex 继续运行")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let refreshedAt = model.backend.lastRefreshedAt {
                Text("最近刷新尝试 \(MenuDate.display(refreshedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("登录时自动启动", isOn: Binding(
                get: { model.launchAtLoginStatus == .enabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .disabled(actionsDisabled || model.isDemo || model.launchAtLoginStatus == .unavailable)
            .help("登录 Mac 后在菜单栏启动；按已选来源恢复本机 API 转发")

            if model.launchAtLoginStatus == .requiresApproval {
                HStack(spacing: 8) {
                    Text("尚未启用，等待系统允许").foregroundStyle(.secondary)
                    Button("前往设置") { model.openLoginItemSettings() }
                    Button("取消申请") { model.setLaunchAtLogin(false) }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .disabled(actionsDisabled)
            } else if model.launchAtLoginStatus == .notFound {
                SmallNotice(text: "系统尚未识别此登录项，可尝试开启重新注册。", warning: true)
            } else if model.launchAtLoginStatus == .unavailable, !model.isDemo {
                SmallNotice(text: "请从 Applications 打开正式应用以设置自启动。", warning: true)
            }

            if let error = model.loginItemError {
                SmallNotice(text: error, warning: true)
            }
        }
    }

    private var loginNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("等待浏览器完成登录")
                .font(.system(size: 12, weight: .semibold))
            Text("请在 OpenAI 官方页面完成登录，账号会自动加入列表。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("取消添加") { model.backend.cancelLogin() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.07))
                .allowsHitTesting(false)
        }
    }

    private func errorNotice(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(message)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭错误提示")
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.orange.opacity(0.09))
                .allowsHitTesting(false)
        }
    }

    private func confirmation(for action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.title)
                .font(.system(size: 13, weight: .semibold))
            if case .rename = action {
                TextField("账号名称", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onAppear { isNameFocused = true }
                    .onSubmit { perform(action) }
            } else {
                Text(action.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if action.isSwitch {
                    Text(previewKey == action.key ? previewText : "正在检查切换条件…")
                        .font(.system(size: 11))
                        .foregroundStyle(previewFailed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(action.recoveryAdvice)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("取消") { pendingAction = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action.confirmTitle, role: action.isRemoval ? .destructive : nil) { perform(action) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || (action.isSwitch && (previewKey != action.key || previewFailed)) || (action.isRename && editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .controlSize(.small)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.045))
                .allowsHitTesting(false)
        }
        .task(id: action.key) {
            guard action.isSwitch else { return }
            previewKey = nil; previewFailed = false
            do {
                let target: SourceTarget
                switch action {
                case .chatGPT(let account): target = .chatGPT(account.id)
                case .copilot, .enableRecording: target = .copilot
                case .copilotIdentity(let account): target = .copilotWithIdentity(account.id)
                case .previous:
                    guard let previous = model.backend.previousSelection else { throw SourceFileError.invalidConfiguration("没有上次组合") }
                    target = try SourceTarget.restoring(previous)
                default: return
                }
                let preview = try await model.backend.previewSwitch(target)
                guard !Task.isCancelled else { return }
                previewText = preview.stableRouting
                    ? "只更新当前登录和模型入口，不迁移对话，也不修改会话索引。旧对话不兼容时请新建。"
                    : "测试模式：不修改正式登录、来源或历史记录。"
                previewKey = action.key
            } catch {
                guard !Task.isCancelled else { return }
                previewText = MenuBackend.safeError(error); previewFailed = true; previewKey = action.key
            }
        }
    }

    private func perform(_ action: PendingAction) {
        guard !model.isBusy else { return }
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if action.isRename && name.isEmpty { return }
        pendingAction = nil
        Task {
            switch action {
            case let .chatGPT(account): await model.backend.selectChatGPT(account.id)
            case .copilot, .enableRecording: await model.backend.selectCopilot()
            case let .copilotIdentity(account): await model.backend.selectCopilot(identity: account.id)
            case .previous: await model.backend.switchBack()
            case let .rename(account): await model.backend.rename(account.id, name: name)
            case let .remove(account): await model.backend.remove(account.id)
            }
        }
    }
}

/// Observe only this account panel, so opening the separate read-only history
/// window does not wake account/quota readers in a hidden account panel.
private struct AccountPanelWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> AccountPanelWindowMarker {
        let view = AccountPanelWindowMarker()
        view.didFindWindow = { value in
            Task { @MainActor in window = value }
        }
        return view
    }
    func updateNSView(_ nsView: AccountPanelWindowMarker, context: Context) {}
}

@MainActor
private final class AccountPanelWindowMarker: NSView {
    var didFindWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didFindWindow?(window)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum PendingAction {
    case chatGPT(AccountProfile)
    case copilot
    case enableRecording
    case copilotIdentity(AccountProfile)
    case previous(String)
    case rename(AccountProfile)
    case remove(AccountProfile)

    var title: String {
        switch self {
        case let .chatGPT(account): "切换到 \(account.displayName)？"
        case .copilot: "切换到 GitHub Copilot？"
        case .enableRecording: "启用逐对话请求记录？"
        case let .copilotIdentity(account): "Copilot ＋ \(account.displayName)？"
        case let .previous(name): "切回 \(name)？"
        case .rename: "重命名账号"
        case let .remove(account): "移除 \(account.displayName)？"
        }
    }

    var explanation: String {
        if case .enableRecording = self {
            return "继续使用 Copilot 和当前官方身份。确认后会结束 Codex 桌面任务、正常退出并更新本机转发，再重新打开。请先保存未发送的输入。"
        }
        if isRemoval {
            return "仅移除本机保存的账号记录与登录副本，不影响远端账号。"
        }
        if case .copilotIdentity = self {
            return "推理使用 Copilot，官方身份使用所选账号。确认后会请求结束当前 Codex 桌面任务并退出重开，请先保存未发送的输入。"
        }
        return "确认后会请求结束当前 Codex 桌面任务并退出重开，只切换账号和模型入口。请先保存未发送的输入。"
    }

    var confirmTitle: String {
        if case .enableRecording = self { return "结束任务并启用记录" }
        if isRename { return "保存名称" }
        if isRemoval { return "移除本地记录" }
        return "结束任务并切换"
    }

    var recoveryAdvice: String {
        if case .enableRecording = self {
            return "若 API 更新后不可用：重新打开「Codex账号」，选择一个有可用额度的 ChatGPT 账号，即可恢复官方推理入口。"
        }
        return "回退：重新打开「Codex账号」，点「切回上次」；也可直接选择一个已保存的 ChatGPT 账号。"
    }

    var isRemoval: Bool {
        if case .remove = self { return true }
        return false
    }

    var isRename: Bool {
        if case .rename = self { return true }
        return false
    }

    var isSwitch: Bool { !isRename && !isRemoval }
    var key: String {
        switch self {
        case .chatGPT(let p): "chatgpt-\(p.id)"
        case .copilot: "copilot"
        case .enableRecording: "enable-recording"
        case .copilotIdentity(let p): "copilot-\(p.id)"
        case .previous(let name): "previous-\(name)"
        case .rename(let p): "rename-\(p.id)"
        case .remove(let p): "remove-\(p.id)"
        }
    }
}
