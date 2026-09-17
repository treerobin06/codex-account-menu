import Foundation

/// The small UI's only application boundary. Account files are delegated to the
/// reviewed store; source changes are delegated to one serialized transaction.
@MainActor
public final class MenuBackend {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var accounts: [AccountProfile] = [] { didSet { changed() } }
    public private(set) var usageStates: [UUID: UsageViewState] = [:] { didSet { changed() } }
    public private(set) var usageFetchedAt: [UUID: Date] = [:] { didSet { changed() } }
    public private(set) var selection = MenuSelection(provider: "openai") { didSet { changed() } }
    public private(set) var previousSelection: MenuSelection? { didSet { changed() } }
    public private(set) var effectiveAuthStatus: EffectiveAuthStatus? { didSet { changed() } }
    public private(set) var officialIdentityError: String? { didSet { changed() } }
    public private(set) var relayError: String? { didSet { changed() } }
    public private(set) var copilotSnapshot: CopilotSnapshot? { didSet { changed() } }
    public private(set) var copilotError: String? { didSet { changed() } }
    public private(set) var isBusy = false { didSet { changed() } }
    public private(set) var isAddingAccount = false { didSet { changed() } }
    public private(set) var status = "正在读取账号" { didSet { changed() } }
    public private(set) var errorMessage: String? { didSet { retryableReadError = nil; changed() } }
    public private(set) var lastRefreshedAt: Date? { didSet { changed() } }
    public private(set) var activitySummary = APIActivitySummary() { didSet { changed() } }

    public let store: AccountStore
    public let codex: any AccountClient
    public let switcher: SourceSwitchService
    private let home: URL
    private let storage: URL
    private let copilotFetcher: @Sendable () async throws -> CopilotSnapshot
    private let demoMode: Bool
    private let relay: (any APIRelayControlling)?
    private let recoveryGuard: any SourceSwitchRecoveryChecking
    private let startupRetryDelays: [Duration]
    public private(set) var startupRetryCount = 0
    private var started = false
    private var needsStartupIdentity = true
    private var needsUsageCache = true
    private enum ReadErrorContext { case source, startupIdentity }
    private var retryableReadError: ReadErrorContext?
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var nativeIdentityConflict = false
    // A refused rollback is a stop boundary for automatic credential readers,
    // whose native helpers and follow-up saves can themselves change OAuth.
    private var sourceRecoveryFailure: SourceSwitchFailure?
    private var readingActivitySummary = false
    private var activityTitles: [UUID: String] = [:]
    private var activityTitlesFetchedAt: Date?
    private var lastActivityTitleLookupID: UUID?

    public init(storageURL: URL? = nil, activeHome: URL? = nil,
                desktop: (any DesktopControlling)? = nil,
                codex suppliedClient: (any AccountClient)? = nil,
                relay suppliedRelay: (any APIRelayControlling)? = nil,
                copilotFetcher: (@Sendable () async throws -> CopilotSnapshot)? = nil,
                recoveryGuard suppliedRecoveryGuard: (any SourceSwitchRecoveryChecking)? = nil,
                startupRetryDelays: [Duration]? = nil,
                demoMode: Bool = false) {
        let user = FileManager.default.homeDirectoryForCurrentUser
        let storage = storageURL ?? user.appending(path: "Library/Application Support/Codex Account Menu")
        let home = activeHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? user.appending(path: ".codex")
        self.home = home
        self.storage = storage
        self.demoMode = demoMode
        recoveryGuard = suppliedRecoveryGuard ?? SwitchRecoveryGuard(baseURL: storage, home: home)
        self.startupRetryDelays = Array((startupRetryDelays ?? ((desktop == nil && !demoMode) ? [.seconds(1), .seconds(3)] : [])).prefix(2))
        store = AccountStore(baseURL: storage, activeHomeURL: home)
        let binary = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let client: any AccountClient = suppliedClient ?? CodexClient(
            locator: .init(explicitURL: binary.map { URL(fileURLWithPath: $0) }),
            requestTimeout: .seconds(20), clientVersion: "0.1.0")
        codex = client
        let relay: (any APIRelayControlling)? = suppliedRelay
            ?? ((desktop == nil && !demoMode) ? APIRelayController(storage: storage) : nil)
        self.relay = relay
        switcher = SourceSwitchService(store: store, codex: client,
            desktop: desktop ?? MacDesktopController(), provider: ProviderConfiguration(codexHome: home),
            relay: relay, activityGuard: relay == nil ? nil : CodexActivityGuard(home: home))
        self.copilotFetcher = copilotFetcher ?? { try await CopilotUsageService().fetch() }
    }

    private func changed() { onChange?() }

    public var officialIdentityAccountID: UUID? {
        guard let auth = effectiveAuthStatus, auth.requiresOpenaiAuth,
              auth.authMethod?.lowercased() == "chatgpt", let identity = auth.identity,
              let profile = accounts.first(where: { $0.id == selection.accountID }),
              identity.accountID != nil, identity.accountID == profile.accountID,
              identity.matches(profile) else { return nil }
        return profile.id
    }

    public func start() async {
        guard !started else { return }
        guard !holdReadsForSourceRecovery() else { return }
        started = true
        if demoMode { status = "演示数据；不会修改 Codex"; return }
        for attempt in 0...startupRetryDelays.count {
            guard !Task.isCancelled, !isBusy, !isAddingAccount, !holdReadsForSourceRecovery() else { return }
            do {
                let lock = try SourceSwitchLock(home: home)
                defer { lock.release() }
                try await prepareCurrentStateLocked()
                await checkEffectiveIdentityLocked()
                status = "已读取当前来源；切换后会正常重开 Codex"
                return
            } catch SourceFileError.busy where attempt < startupRetryDelays.count {
                startupRetryCount += 1
                status = "启动时暂有占用，稍后重试（\(startupRetryCount)/\(startupRetryDelays.count)）"
                do { try await Task.sleep(for: startupRetryDelays[attempt]) }
                catch { return }
            } catch {
                failRead("读取账号失败", error, context: .source)
                _ = holdReadsForSourceRecovery()
                return
            }
        }
    }

    /// Also runs on refresh: login can finish before another client releases
    /// the source lock or before the configured local relay is available.
    private func prepareCurrentStateLocked() async throws {
        try recoveryGuard.requireSafeAutomaticWork()
        if needsStartupIdentity {
            _ = try await store.reloadRegistry()
            if await store.activeCredentialExists() {
                do {
                    let identity = try await codex.readIdentity(profileHome: home)
                    try await store.registerActiveIdentity(identity)
                    needsStartupIdentity = false
                    clearReadError(.startupIdentity)
                } catch {
                    failRead("当前登录暂时无法核验。已保存账号仍保留。", error, context: .startupIdentity)
                }
            } else {
                needsStartupIdentity = false
                clearReadError(.startupIdentity)
            }
        }
        try await reloadLocked()
        await ensureConfiguredRelayLocked()
        if needsUsageCache {
            let cache = try await store.loadUsageCache()
            for item in cache.entries {
                usageFetchedAt[item.profileID] = item.fetchedAt
                usageStates[item.profileID] = .stale(item.usage, "缓存于 " + item.fetchedAt.formatted(date: .abbreviated, time: .shortened))
            }
            needsUsageCache = false
        }
        clearReadError(.source)
    }

    private func reload() async throws {
        let lock = try SourceSwitchLock(home: home)
        defer { lock.release() }
        try await reloadLocked()
    }

    private func reloadLocked() async throws {
        let registry = try await store.sourceSnapshot(targetID: nil)
        let provider = ProviderConfiguration(codexHome: home)
        let configuration = try await provider.snapshot()
        let route = try await provider.readRoute()
        let previous = try SourceFileSnapshot.read(storage.appending(path: "previous-source.json"))
        let saved = previous.data.flatMap { try? JSONDecoder().decode(MenuSelection.self, from: $0) }
        try registry.registryFile.requireUnchanged()
        try configuration.file.requireUnchanged()
        try previous.requireUnchanged()
        accounts = registry.registry.accounts
        selection = MenuSelection(route: route, accountID: registry.registry.activeAccountID)
        previousSelection = saved
    }

    private func ensureConfiguredRelayLocked() async {
        guard let relay else { return }
        relayError = nil
        do {
            try recoveryGuard.requireSafeAutomaticWork()
            let config = ProviderConfiguration(codexHome: home)
            let snapshot = try await config.snapshot()
            let route = try await config.readRoute()
            if route.isManaged && route.apiEnabled {
                let state: APIRelayStatus
                if let running = try await relay.status() { state = running }
                else { state = try await relay.ensureRunning() }
                try snapshot.file.requireUnchanged()
                if !state.enabled { _ = try await relay.setEnabled(true) }
            }
        } catch { relayError = Self.safeError(error) }
    }

    public func previewSwitch(_ target: SourceTarget) async throws -> SourceSwitchPreview {
        await refreshTask?.value
        return try await switcher.preview(to: target)
    }

    private func checkEffectiveIdentityLocked() async {
        guard !holdReadsForSourceRecovery() else { return }
        effectiveAuthStatus = nil
        officialIdentityError = nil
        if let relay {
            do {
                let route = try await ProviderConfiguration(codexHome: home).readRoute()
                if route.isManaged && route.apiEnabled {
                    guard let state = try await relay.status(), state.enabled else {
                        throw APIRelayError.unavailable("转发未运行；点击刷新重试，或直接选择 ChatGPT 账号回退")
                    }
                }
                relayError = nil
            } catch {
                // Keep a concrete ensureRunning failure from this refresh;
                // the later status check only knows that no relay is running.
                if relayError == nil { relayError = Self.safeError(error) }
            }
        }
        do {
            let config = try await ProviderConfiguration(codexHome: home).snapshot()
            let route = try await ProviderConfiguration(codexHome: home).readRoute()
            let registry = try await store.sourceSnapshot(targetID: nil)
            let auth = try await codex.readEffectiveAuthStatus(profileHome: home)
            try config.file.requireUnchanged()
            try registry.registryFile.requireUnchanged()
            accounts = registry.registry.accounts
            selection = MenuSelection(route: route, accountID: registry.registry.activeAccountID)
            if selection.officialIdentityDisabled {
                officialIdentityError = "当前运行时未连接官方身份"
                return
            }
            if nativeIdentityConflict {
                selection = MenuSelection(provider: config.provider)
                officialIdentityError = "同轮账号与额度身份不一致，请导入当前登录后重试"
                return
            }
            guard auth.requiresOpenaiAuth, auth.authMethod?.lowercased() == "chatgpt",
                  let identity = auth.identity else {
                officialIdentityError = "当前运行时未连接官方身份"
                return
            }
            guard let profile = accounts.first(where: { $0.id == selection.accountID }),
                  identity.accountID != nil, identity.accountID == profile.accountID,
                  identity.matches(profile) else {
                officialIdentityError = "运行时身份与保存账号不一致，请导入当前登录"
                return
            }
            // The effective-config helper must finish before the caller releases
            // SourceSwitchLock; preserve any native OAuth rotation it performed.
            try await store.saveCurrentCredential()
            effectiveAuthStatus = auth
        } catch { officialIdentityError = "本次未能核验官方身份：" + Self.safeError(error) }
    }

    private func checkEffectiveIdentity() async {
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            await checkEffectiveIdentityLocked()
        } catch {
            effectiveAuthStatus = nil
            officialIdentityError = Self.safeError(error)
        }
    }

    public func refresh(force: Bool = false) async {
        if demoMode { lastRefreshedAt = Date(); status = "演示数据已刷新"; return }
        guard !isBusy, !isAddingAccount else { return }
        guard !holdReadsForSourceRecovery() else { return }
        if let task = refreshTask { await task.value; return }
        if !force, let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < 60 { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        status = "正在读取额度"
        nativeIdentityConflict = false
        effectiveAuthStatus = nil
        officialIdentityError = "正在核验当前配置"
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            try await prepareCurrentStateLocked()
        }
        catch {
            officialIdentityError = Self.safeError(error)
            failRead("来源暂时无法读取，稍后刷新", error, context: .source)
            return
        }
        let profiles = accounts
        // Keep account refreshes serialized: the active native token may rotate.
        // Copilot runs independently and its credentials remain on the configured proxy host.
        async let remote: Result<CopilotSnapshot, any Error> = fetchCopilot()
        for profile in profiles {
            do {
                let lock = try SourceSwitchLock(home: home)
                defer { lock.release() }
                try recoveryGuard.requireSafeAutomaticWork()
                let registry = try await store.reloadRegistry()
                guard registry.accounts.contains(where: { $0.id == profile.id }) else { continue }
                let targetHome = profile.id == registry.activeAccountID ? home : await store.profileHome(id: profile.id)
                let reading = try await codex.readAccountUsage(profileHome: targetHome)
                guard reading.identity.accountID != nil,
                      reading.identity.accountID == profile.accountID,
                      reading.identity.matches(profile) else {
                    if profile.id == registry.activeAccountID {
                        nativeIdentityConflict = true
                        selection = MenuSelection(provider: selection.provider,
                            officialIdentityDisabled: selection.officialIdentityDisabled)
                        errorMessage = "Codex 的原生登录已变化，请点“导入当前登录”同步。未将其他账号额度写入本账号。"
                    }
                    throw AccountStoreError.activeCredentialMismatch
                }
                // Validate/save any rotation before publishing or caching a value.
                if profile.id == registry.activeAccountID { try await store.saveCurrentCredential() }
                let fetchedAt = Date()
                try await store.cacheWeeklyUsage(reading.usage, profileID: profile.id, fetchedAt: fetchedAt)
                usageFetchedAt[profile.id] = fetchedAt
                usageStates[profile.id] = .loaded(reading.usage)
            } catch {
                let message = Self.safeError(error)
                if let old = usageStates[profile.id]?.displayedUsage {
                    let timestamp = usageFetchedAt[profile.id].map { "数据时间：" + $0.formatted(date: .abbreviated, time: .shortened) + "\n" } ?? "数据时间未知\n"
                    usageStates[profile.id] = .stale(old, timestamp + message)
                }
                else { usageStates[profile.id] = .unavailable(message) }
            }
        }
        switch await remote {
        case let .success(value): copilotSnapshot = value; copilotError = nil
        case let .failure(error): copilotError = Self.safeError(error)
        }
        await checkEffectiveIdentity()
        guard !holdReadsForSourceRecovery() else { return }
        lastRefreshedAt = Date()
        status = copilotError == nil && !usageStates.values.contains(where: {
            if case .loaded = $0 { return false }; return true
        })
            ? "额度已更新" : "部分额度暂不可用；旧数据保留查询时间"
    }

    private func fetchCopilot() async -> Result<CopilotSnapshot, any Error> {
        do { return .success(try await copilotFetcher()) }
        catch { return .failure(error) }
    }

    public func selectChatGPT(_ id: UUID) async { await select(.chatGPT(id)) }
    public func selectCopilot() async { await select(.copilot) }
    public func selectCopilot(identity id: UUID) async { await select(.copilotWithIdentity(id)) }

    private func select(_ target: SourceTarget?) async {
        guard !isBusy, !isAddingAccount else { return }
        if demoMode {
            guard let target = target ?? previousSelection.flatMap({ try? SourceTarget.restoring($0) }) else { return }
            let targetSelection: MenuSelection
            switch target {
            case let .chatGPT(id): targetSelection = MenuSelection(provider: "openai", accountID: id)
            case .copilot: targetSelection = MenuSelection(provider: "copilot", accountID: selection.accountID)
            case let .copilotWithIdentity(id): targetSelection = MenuSelection(provider: "copilot", accountID: id)
            case .copilotWithoutOfficialIdentity:
                targetSelection = MenuSelection(provider: "copilot", officialIdentityDisabled: true)
            }
            previousSelection = selection; selection = targetSelection
            status = "演示：已选择来源，没有修改或重开 Codex"
            return
        }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        status = "准备切换；等待额度读取结束"
        await refreshTask?.value
        effectiveAuthStatus = nil
        officialIdentityError = nil
        do {
            status = "正在正常退出、保存登录并切换；请稍候"
            if let target { _ = try await switcher.switchSource(to: target) }
            else { _ = try await switcher.restorePreviousSelection() }
            sourceRecoveryFailure = nil
            nativeIdentityConflict = false
            try await reload()
            await checkEffectiveIdentity()
            status = "来源已切换，Codex 已重开；历史记录未改动"
        } catch {
            let earlierRecovery = sourceRecoveryFailure
            if sourceRecoveryFailure == nil, let failure = error as? SourceSwitchFailure,
               failure.sourceMutationAttempted, !failure.previousSelectionRestored {
                sourceRecoveryFailure = failure
            }
            try? await reload()
            if sourceRecoveryFailure == nil { await checkEffectiveIdentity() }
            fail("切换未完成，请查看恢复结果", error)
            if let earlierRecovery {
                errorMessage = (errorMessage ?? "") + "\n此前仍未完成的恢复：\n" + Self.safeError(earlierRecovery)
            }
            _ = holdReadsForSourceRecovery()
        }
    }

    public func switchBack() async {
        await select(nil)
    }

    public func importCurrentAccount() async {
        guard !isBusy, !isAddingAccount else { return }
        guard !holdReadsForSourceRecovery() else { return }
        if demoMode { status = "演示：当前账号已在列表中"; return }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            try recoveryGuard.requireSafeAutomaticWork()
            let identity = try await codex.readIdentity(profileHome: home)
            try await store.registerActiveIdentity(identity)
            nativeIdentityConflict = false
            try await reloadLocked()
            await checkEffectiveIdentityLocked()
            status = "当前登录已导入；原生登录和来源未改动"
        } catch { fail("导入当前登录失败", error) }
    }

    public func addAccount() async {
        guard !isBusy, !isAddingAccount else { return }
        guard !holdReadsForSourceRecovery() else { return }
        isAddingAccount = true
        errorMessage = nil
        status = "等待浏览器完成官方登录；可以取消"
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performLogin()
        }
        loginTask = task
        await task.value
        loginTask = nil
        isAddingAccount = false
    }

    private func performLogin() async {
        let id = UUID()
        if demoMode {
            do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() }
            catch { status = "演示登录已取消"; return }
            accounts.append(AccountProfile(id: id, displayName: "演示账号", email: "demo@example.test", accountID: "demo-" + id.uuidString, createdAt: Date()))
            status = "演示账号已添加；未创建任何真实登录"
            return
        }
        do {
            // Cancelling an added login must not wait for the network refresh
            // or cancel that refresh while it may be saving rotated credentials.
            while refreshTask != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            let profileHome: URL
            do {
                let lock = try SourceSwitchLock(home: home)
                defer { lock.release() }
                try recoveryGuard.requireSafeAutomaticWork()
                profileHome = try await store.createProfileDirectory(id: id)
            }
            try Task.checkCancellation()
            let identity = try await codex.login(profileHome: profileHome)
            try Task.checkCancellation()
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            try recoveryGuard.requireSafeAutomaticWork()
            _ = try await store.reloadRegistry()
            try await store.addProfile(AccountProfile(id: id, displayName: identity.suggestedDisplayName,
                email: identity.email, accountID: identity.accountID, createdAt: Date()))
            accounts = try await store.loadRegistry().accounts
            status = "账号已保存，尚未切换当前 Codex"
        } catch {
            // A failed login may clean only its own unpublished profile, under
            // the same source lock. Keep it if another switch owns the lock.
            if let cleanupLock = try? SourceSwitchLock(home: home) {
                try? await store.discardUnregisteredProfile(id: id)
                cleanupLock.release()
            }
            if error is CancellationError { status = "登录已取消，当前来源未变" }
            else { fail("添加账号失败", error) }
        }
    }

    public func cancelLogin() { loginTask?.cancel() }

    public func prepareToQuit() async -> Bool {
        guard !isBusy, !isAddingAccount else { return false }
        isBusy = true
        status = "等待额度读取结束后退出小工具"
        await refreshTask?.value
        return true
    }

    public func rename(_ id: UUID, name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !isAddingAccount, !clean.isEmpty else { return }
        guard !holdReadsForSourceRecovery() else { return }
        if demoMode {
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].displayName = clean }
            return
        }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            try recoveryGuard.requireSafeAutomaticWork()
            _ = try await store.reloadRegistry()
            try await store.renameAccount(id: id, displayName: clean)
            accounts = try await store.loadRegistry().accounts
        } catch { fail("重命名失败", error) }
    }

    public func remove(_ id: UUID) async {
        guard !isBusy, !isAddingAccount else { return }
        guard !holdReadsForSourceRecovery() else { return }
        if demoMode {
            guard selection.accountID != id else { errorMessage = "请先切换到其他账号再移除"; return }
            accounts.removeAll { $0.id == id }; usageStates[id] = nil
            return
        }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            try recoveryGuard.requireSafeAutomaticWork()
            _ = try await store.reloadRegistry()
            try await store.removeAccount(id: id)
            accounts = try await store.loadRegistry().accounts
            usageStates[id] = nil
            status = "已移除本地记录；没有撤销远端账号"
        } catch { fail("移除账号失败", error) }
    }

    public func dismissError() { errorMessage = nil }

    public func refreshActivitySummary() async {
        guard !readingActivitySummary else { return }
        readingActivitySummary = true
        defer { readingActivitySummary = false }
        do {
            if !demoMode { try AccountStoreBinding.requireExisting(base: storage, home: home) }
            let state: APIRelayStatus?
            if demoMode { state = Self.demoActivity().relay }
            else { state = try await relay?.status() }
            let snapshot = ConversationActivitySnapshot(conversations: [], relay: state)
            let latest = snapshot.observations.compactMap { record in
                record.updatedDate.map { ($0, record) }
            }.max { $0.0 < $1.0 }?.1
            if let id = latest?.threadUUID,
               (activityTitles[id] == nil && lastActivityTitleLookupID != id)
                || Date().timeIntervalSince(activityTitlesFetchedAt ?? .distantPast) > 60 {
                let conversations = demoMode ? Self.demoActivity().conversations : (try? await ConversationCatalog(home: home).recent()) ?? []
                activityTitles = Dictionary(conversations.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                activityTitlesFetchedAt = Date()
                lastActivityTitleLookupID = id
            }
            guard !Task.isCancelled else { return }
            if !demoMode { try AccountStoreBinding.requireExisting(base: storage, home: home) }
            activitySummary = APIActivitySummary(relay: state, latest: latest,
                conversationTitle: latest?.threadUUID.flatMap { activityTitles[$0] }, checkedAt: Date())
        } catch {
            guard !Task.isCancelled else { return }
            activitySummary = APIActivitySummary(relay: activitySummary.relay, latest: activitySummary.latest,
                conversationTitle: activitySummary.conversationTitle, checkedAt: Date(), error: Self.safeError(error))
        }
    }

    /// Local read-only diagnostics. Never starts a relay or an account helper.
    public func readConversationActivity() async -> ConversationActivitySnapshot {
        if demoMode { return Self.demoActivity() }
        var conversations: [ConversationSummary] = []
        var relayState: APIRelayStatus?
        var catalogError: String?, observationError: String?
        do { conversations = try await ConversationCatalog(home: home).recent() }
        catch { catalogError = Self.safeError(error) }
        do {
            try AccountStoreBinding.requireExisting(base: storage, home: home)
            relayState = try await relay?.status()
            try AccountStoreBinding.requireExisting(base: storage, home: home)
        }
        catch { observationError = Self.safeError(error) }
        return ConversationActivitySnapshot(conversations: conversations, relay: relayState,
            catalogError: catalogError, relayError: observationError)
    }

    public func readConversationPreview(_ conversation: ConversationSummary) async throws -> ConversationPreview {
        if demoMode {
            return ConversationPreview(messages: [
                ConversationMessagePreview(id: "demo-prompt", role: "user", text: "这是演示 Prompt：帮我核对这次请求的去向。", timestamp: Date().addingTimeInterval(-60)),
                ConversationMessagePreview(id: "demo-reply", role: "assistant", text: "这是演示回答。此窗口的数据只用于检查布局，没有读取或发送真实对话。", timestamp: Date().addingTimeInterval(-30))
            ], limited: false)
        }
        return try await ConversationCatalog(home: home).preview(for: conversation)
    }

    private static func demoActivity() -> ConversationActivitySnapshot {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let now = Date().ISO8601Format()
        let conversations = [
            ConversationSummary(id: id, title: "演示 · 核对请求去向", cwd: "/演示项目", lastUpdatedAt: Date(), storedProvider: "openai", sessionID: nil, rolloutPath: ""),
            ConversationSummary(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, title: "演示 · 尚未观测到请求", cwd: "/演示项目", lastUpdatedAt: Date(), storedProvider: "openai", sessionID: nil, rolloutPath: "")
        ]
        var state = APIRelayStatus(protocolVersion: 1, pid: 1, instanceId: UUID().uuidString, host: "127.0.0.1", port: 4142,
            baseURL: "http://127.0.0.1:4142/v1", enabled: true, activeRequests: 0, activeWebSockets: 1, testMode: true, upstreamPort: 4141)
        state.observationVersion = 1; state.observationLimit = 100
        state.recentRequests = [RelayRequestObservation(id: UUID().uuidString, startedAt: now, updatedAt: now,
            threadID: id.uuidString, sessionID: nil, transport: "websocket", phase: "websocket_open", statusCode: 101, route: "copilot")]
        return ConversationActivitySnapshot(conversations: conversations, relay: state)
    }

    /// Only a completed explicit source transaction releases this hold. A
    /// dismissed message, retry failure or panel refresh cannot acknowledge it.
    @discardableResult
    private func holdReadsForSourceRecovery() -> Bool {
        if demoMode { return false }
        var detail = sourceRecoveryFailure.map { Self.safeError($0) }
        do { try recoveryGuard.requireSafeAutomaticWork() }
        catch { if detail == nil { detail = Self.safeError(error) } }
        guard let detail else { return false }
        // Keep explicit source selection usable after restarting the menu.
        // Decode metadata directly: loadRegistry may establish a binding/write.
        if accounts.isEmpty { loadRecoveryAccountMetadata() }
        effectiveAuthStatus = nil
        officialIdentityError = "上次切换未完整恢复，自动身份核验已暂停"
        status = "已暂停自动读取；请检查恢复结果后重新选择来源"
        if errorMessage == nil {
            errorMessage = "上次切换仍需恢复\n" + detail
        }
        return true
    }

    private func loadRecoveryAccountMetadata() {
        do {
            let lock = try SourceSwitchLock(home: home)
            defer { lock.release() }
            guard try recoveryGuard.pendingRecord() != nil else { return }
            let file = try SourceFileSnapshot.read(storage.appending(path: "accounts.json"))
            guard let data = file.data, data.count <= 1_048_576 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let registry = try decoder.decode(AccountRegistry.self, from: data)
            try file.requireUnchanged()
            accounts = registry.accounts
            selection = MenuSelection(provider: "")
        } catch { /* Preserve the original recovery error and all files. */ }
    }

    private func fail(_ title: String, _ error: any Error) {
        errorMessage = title + "\n" + Self.safeError(error)
        status = title
    }

    private func failRead(_ title: String, _ error: any Error, context: ReadErrorContext) {
        // A temporary read failure must not replace an undismissed source
        // switch/recovery error and then erase it when the next read succeeds.
        if errorMessage != nil, retryableReadError == nil {
            officialIdentityError = title + "\n" + Self.safeError(error)
            status = title
            return
        }
        fail(title, error)
        retryableReadError = context
    }

    private func clearReadError(_ context: ReadErrorContext) {
        if retryableReadError == context { errorMessage = nil }
    }

    public static func safeError(_ error: any Error) -> String {
        let raw = error.localizedDescription
        let redacted = raw.replacingOccurrences(of: "(?:sk-[A-Za-z0-9_-]+|gh[opusr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|Bearer\\s+\\S+|eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)", with: "[已隐藏凭据]", options: .regularExpression)
        return String(redacted.prefix(500))
    }

    public static func demo() -> MenuBackend {
        let value = MenuBackend(storageURL: URL(fileURLWithPath: "/tmp/codex-menu-demo-unused"),
                                activeHome: URL(fileURLWithPath: "/tmp/codex-menu-demo-unused/home"), demoMode: true)
        let a = AccountProfile(id: UUID(), displayName: "Demo", email: "demo@example.test", accountID: "demo-account", createdAt: Date())
        let b = AccountProfile(id: UUID(), displayName: "另一个账号", email: "second@example.test", accountID: "demo-second", createdAt: Date())
        value.accounts = [a, b]
        value.selection = MenuSelection(provider: "copilot")
        value.previousSelection = MenuSelection(provider: "openai", accountID: a.id)
        value.usageStates = [a.id: .loaded(WeeklyUsage(remainingPercent: 9, resetsAt: Date().addingTimeInterval(6 * 86400), fiveHourRemainingPercent: 64, fiveHourResetsAt: Date().addingTimeInterval(3 * 3600))),
                             b.id: .loaded(WeeklyUsage(remainingPercent: 72, resetsAt: Date().addingTimeInterval(3 * 86400)))]
        value.copilotSnapshot = CopilotSnapshot(observedAt: Date(), login: "demo-copilot", plan: "enterprise",
            remainingPercent: 96.6, resetsAt: Date().addingTimeInterval(14 * 86400), tokenBasedBilling: true, overagePermitted: true, modelsAvailable: 37)
        value.lastRefreshedAt = Date()
        value.status = "演示数据；不会修改 Codex"
        return value
    }
}
