import Foundation
import Testing
@testable import SwitcherCore

@MainActor
@Suite(.serialized)
struct MenuBackendTests {
    @Test func activityDoesNotAssociateARelayWithAnotherBoundHome() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        let before = await fixture.client.callCounts()
        let other = fixture.root.appending(path: "other-home")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let rebuilt = MenuBackend(storageURL: fixture.storage, activeHome: other,
            desktop: fixture.desktop, codex: fixture.client, relay: BackendRelay())
        await rebuilt.refreshActivitySummary()
        #expect(rebuilt.activitySummary.relay == nil)
        #expect(rebuilt.activitySummary.error?.contains("另一个") == true)
        let activity = await rebuilt.readConversationActivity()
        #expect(activity.relay == nil)
        #expect(activity.relayError?.contains("另一个") == true)
        #expect(await fixture.client.callCounts() == before)
    }
    @Test func restartKeepsPendingRecoveryAndSavedAccountsWithoutCallingUpstream() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        let saved = fixture.backend.accounts
        let pending = SourceSwitchPendingRecord(home: fixture.active)
        let file = fixture.storage.appending(path: "switch-pending.json")
        let pendingBytes = try JSONEncoder().encode(pending)
        try pendingBytes.write(to: file)
        let before = await fixture.client.callCounts()
        let rebuilt = MenuBackend(storageURL: fixture.storage, activeHome: fixture.active,
            desktop: fixture.desktop, codex: fixture.client)
        await rebuilt.start()
        #expect(rebuilt.accounts == saved)
        #expect(rebuilt.officialIdentityAccountID == nil)
        rebuilt.dismissError()
        await rebuilt.refresh(force: true)
        await rebuilt.importCurrentAccount()
        await rebuilt.addAccount()
        if let id = saved.first?.id {
            await rebuilt.rename(id, name: "must-not-change")
            await rebuilt.remove(id)
        }
        #expect(await fixture.client.callCounts() == before)
        #expect(rebuilt.errorMessage?.contains("恢复") == true)
        #expect(try Data(contentsOf: file) == pendingBytes)
        #expect(rebuilt.accounts == saved)
    }

    @Test func startupRetriesOnlyBoundedLockContention() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let lock = try SourceSwitchLock(home: fixture.active)
        let backend = MenuBackend(storageURL: fixture.storage, activeHome: fixture.active,
            desktop: fixture.desktop, codex: fixture.client, startupRetryDelays: [.milliseconds(30), .milliseconds(60)])
        let attempt = Task { await backend.start() }
        while backend.startupRetryCount == 0 { await Task.yield() }
        lock.release()
        await attempt.value
        #expect(backend.startupRetryCount == 1)
        #expect(!backend.accounts.isEmpty)
        #expect(await fixture.desktop.closes == 0)
    }

    @Test func startupStopsRetryingIfRecoveryBecomesPending() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        let before = await fixture.client.callCounts()
        let lock = try SourceSwitchLock(home: fixture.active)
        let backend = MenuBackend(storageURL: fixture.storage, activeHome: fixture.active,
            desktop: fixture.desktop, codex: fixture.client, startupRetryDelays: [.milliseconds(40), .milliseconds(40)])
        let attempt = Task { await backend.start() }
        while backend.startupRetryCount == 0 { await Task.yield() }
        try JSONEncoder().encode(SourceSwitchPendingRecord(home: fixture.active))
            .write(to: fixture.storage.appending(path: "switch-pending.json"))
        lock.release()
        await attempt.value
        #expect(backend.startupRetryCount == 1)
        #expect(await fixture.client.callCounts() == before)
        #expect(backend.errorMessage?.contains("恢复") == true)
    }

    @Test func conversationDiagnosticsNeverCallAccountsOrStartRelay() async throws {
        let relay = RecoveringBackendRelay()
        let fixture = try BackendFixture(relay: relay)
        defer { fixture.clean() }
        let result = await fixture.backend.readConversationActivity()
        await fixture.backend.refreshActivitySummary()
        #expect(result.catalogError != nil) // No index in this fixture.
        #expect(await fixture.client.callCounts() == [0, 0, 0, 0, 0])
        #expect(await relay.mutationCounts() == [0, 0])
        #expect(fixture.backend.activitySummary.checkedAt != nil)
        #expect(fixture.backend.activitySummary.timestamp == nil)
    }

    @Test func refreshRecoversStartupLockContentionWithoutChangingTheSource() async throws {
        let relay = RecoveringBackendRelay()
        let fixture = try BackendFixture(relay: relay)
        defer { fixture.clean() }
        await relay.expectSourceLock(at: fixture.active)
        let provider = ProviderConfiguration(codexHome: fixture.active)
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: true, expecting: provider.snapshot())
        let config = try SourceFileSnapshot.read(fixture.active.appending(path: "config.toml"))
        let auth = try SourceFileSnapshot.read(fixture.active.appending(path: "auth.json"))
        let lock = try SourceSwitchLock(home: fixture.active)
        defer { lock.release() }
        await fixture.backend.start()
        #expect(fixture.backend.accounts.isEmpty)
        #expect(fixture.backend.errorMessage != nil)
        #expect(await relay.mutationCounts() == [0, 0])
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.accounts.isEmpty)
        #expect(fixture.backend.errorMessage != nil)
        #expect(await relay.mutationCounts() == [0, 0])
        lock.release()

        await fixture.backend.refresh(force: true)
        let id = try #require(fixture.backend.accounts.first?.id)
        #expect(fixture.backend.selection == MenuSelection(provider: "copilot", accountID: id))
        #expect(fixture.backend.officialIdentityAccountID == id)
        #expect(fixture.backend.errorMessage == nil && fixture.backend.relayError == nil)
        #expect(fixture.backend.copilotError != nil) // This refresh's independent SSH error is retained.
        #expect(await relay.mutationCounts() == [1, 1])
        #expect(await relay.isEnabled())
        #expect(await fixture.desktop.closes == 0)
        try config.requireUnchanged()
        try auth.requireUnchanged()
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "previous-source.json").path))
    }

    @Test func refreshRetriesAFailedConfiguredRelayAndThenReusesIt() async throws {
        let relay = RecoveringBackendRelay(startupFailures: 1)
        let fixture = try BackendFixture(relay: relay)
        defer { fixture.clean() }
        await relay.expectSourceLock(at: fixture.active)
        let provider = ProviderConfiguration(codexHome: fixture.active)
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: false, expecting: provider.snapshot())
        let config = try SourceFileSnapshot.read(fixture.active.appending(path: "config.toml"))
        let auth = try SourceFileSnapshot.read(fixture.active.appending(path: "auth.json"))
        await fixture.backend.start()
        #expect(fixture.backend.relayError?.contains("synthetic startup failure") == true)
        #expect(await relay.mutationCounts() == [1, 0])

        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.relayError == nil)
        #expect(fixture.backend.selection == MenuSelection(provider: "copilot", officialIdentityDisabled: true))
        #expect(fixture.backend.officialIdentityAccountID == nil)
        #expect(await relay.mutationCounts() == [2, 1])
        await fixture.backend.refresh(force: true)
        #expect(await relay.mutationCounts() == [2, 1])
        #expect(await relay.isEnabled())
        #expect(await fixture.desktop.closes == 0)
        try config.requireUnchanged()
        try auth.requireUnchanged()
    }

    @Test(arguments: ["native", "unmanaged-api", "managed-native"])
    func refreshDoesNotStartOrChangeARelayOutsideManagedAPI(mode: String) async throws {
        let relay = RecoveringBackendRelay(running: true, enabled: true, activeRequests: 1)
        let fixture = try BackendFixture(relay: relay)
        defer { fixture.clean() }
        await relay.expectSourceLock(at: fixture.active)
        let provider = ProviderConfiguration(codexHome: fixture.active)
        if mode == "unmanaged-api" {
            _ = try await provider.setProvider("copilot", expecting: provider.snapshot())
        } else if mode == "managed-native" {
            _ = try await provider.setRoute("openai", hasOfficialIdentity: true, expecting: provider.snapshot())
        }
        let route = try await provider.readRoute()
        #expect(!route.isManaged || !route.apiEnabled)
        let config = try SourceFileSnapshot.read(fixture.active.appending(path: "config.toml"))
        let auth = try SourceFileSnapshot.read(fixture.active.appending(path: "auth.json"))
        await fixture.backend.start()
        await fixture.backend.refresh(force: true)
        #expect(await relay.mutationCounts() == [0, 0])
        #expect(await relay.isEnabled())
        #expect(await fixture.desktop.closes == 0)
        try config.requireUnchanged()
        try auth.requireUnchanged()
    }

    @Test func refreshKeepsAnEnabledBusyRelayInPlace() async throws {
        let relay = RecoveringBackendRelay(running: true, enabled: true, activeRequests: 1)
        let fixture = try BackendFixture(relay: relay)
        defer { fixture.clean() }
        await relay.expectSourceLock(at: fixture.active)
        let provider = ProviderConfiguration(codexHome: fixture.active)
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: true, expecting: provider.snapshot())
        await fixture.backend.start()
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.relayError == nil)
        #expect(await relay.mutationCounts() == [0, 0])
        #expect(await relay.isEnabled())
    }

    @Test func refreshRecoversStartupIdentityReadButPreservesALaterSwitchError() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.client.failNextIdentityRead()
        await fixture.backend.start()
        #expect(fixture.backend.errorMessage?.contains("当前登录暂时无法核验") == true)
        #expect(fixture.backend.accounts.isEmpty)
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.errorMessage == nil)
        #expect(fixture.backend.officialIdentityAccountID == fixture.backend.accounts.first?.id)

        await fixture.backend.selectChatGPT(UUID())
        let switchError = try #require(fixture.backend.errorMessage)
        #expect(switchError.contains("切换未完成"))
        let lock = try SourceSwitchLock(home: fixture.active)
        defer { lock.release() }
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.errorMessage == switchError)
        #expect(fixture.backend.officialIdentityError != nil)
        lock.release()
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.errorMessage == switchError)
        #expect(fixture.backend.officialIdentityError == nil)
        #expect(await fixture.desktop.closes == 0)
    }

    @Test func previousCombinationUsesStoppedStateAfterAnExternalSourceChange() async throws {
        let fixture = try BackendFixture(managedRelay: true)
        defer { fixture.clean() }
        await fixture.backend.start()
        let id = try #require(fixture.backend.accounts.first?.id)
        let provider = ProviderConfiguration(codexHome: fixture.active)
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: false, expecting: provider.snapshot())
        let pure = MenuSelection(provider: "copilot", officialIdentityDisabled: true)
        // The panel still displays native A while another caller changed the route.
        await fixture.backend.selectCopilot(identity: id)
        #expect(fixture.backend.errorMessage == nil)
        let persisted = try JSONDecoder().decode(MenuSelection.self,
            from: Data(contentsOf: fixture.storage.appending(path: "previous-source.json")))
        #expect(persisted == pure)
        #expect(fixture.backend.previousSelection == persisted)
        await fixture.backend.switchBack()
        #expect(fixture.backend.errorMessage == nil)
        #expect(fixture.backend.selection == pure)
        #expect(fixture.backend.officialIdentityAccountID == nil)
    }

    @Test func backResolvesTheAuthoritativePreviousRecordAfterAnotherCallerSwitches() async throws {
        let fixture = try BackendFixture(managedRelay: true)
        defer { fixture.clean() }
        await fixture.backend.start()
        let id = try #require(fixture.backend.accounts.first?.id)
        await fixture.backend.selectCopilot(identity: id)
        #expect(fixture.backend.previousSelection?.provider == "openai")
        let pure = MenuSelection(provider: "copilot", officialIdentityDisabled: true)
        // Use the same backend's service as a second caller: it updates disk only.
        _ = try await fixture.backend.switcher.restoreSelection(pure)
        await fixture.backend.switchBack()
        #expect(fixture.backend.errorMessage == nil)
        #expect(fixture.backend.selection == MenuSelection(provider: "copilot", accountID: id))
        #expect(fixture.backend.previousSelection == pure)
    }

    @Test func managedPureAPIReadRefreshAndBackPreserveDisconnectedIdentity() async throws {
        let fixture = try BackendFixture(managedRelay: true)
        defer { fixture.clean() }
        let provider = ProviderConfiguration(codexHome: fixture.active)
        let original = try await provider.snapshot()
        _ = try await provider.setRoute("copilot", hasOfficialIdentity: false, expecting: original)
        await fixture.backend.start()
        let pure = MenuSelection(provider: "copilot", officialIdentityDisabled: true)
        #expect(fixture.backend.selection == pure)
        #expect(fixture.backend.officialIdentityAccountID == nil)
        let id = try #require(fixture.backend.accounts.first?.id)
        await fixture.backend.selectChatGPT(id)
        #expect(fixture.backend.selection == MenuSelection(provider: "openai", accountID: id))
        #expect(fixture.backend.previousSelection == pure)
        let before = await fixture.client.verificationCalls
        await fixture.backend.switchBack()
        #expect(fixture.backend.errorMessage == nil)
        #expect(fixture.backend.selection == pure)
        #expect(fixture.backend.officialIdentityAccountID == nil)
        #expect(await fixture.client.verificationCalls == before)
        await fixture.client.returnWrongAccount()
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.selection == pure)
        #expect(fixture.backend.officialIdentityAccountID == nil)
    }

    @Test func nativeAccountReadDoesNotProveEffectiveOfficialIdentity() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.client.setEffectiveAuth(.init(authMethod: nil, requiresOpenaiAuth: false, identity: nil))
        await fixture.backend.start()
        #expect(fixture.backend.accounts.count == 1)
        #expect(fixture.backend.selection.accountID != nil)
        #expect(fixture.backend.officialIdentityAccountID == nil)
        #expect(fixture.backend.officialIdentityError != nil)
        await fixture.client.setEffectiveAuth(.init(authMethod: "chatgpt", requiresOpenaiAuth: true,
                                                    identity: .init(accountID: "A", email: "a@example.test")))
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.officialIdentityAccountID == fixture.backend.accounts.first?.id)
        #expect(fixture.backend.officialIdentityError == nil)
    }

    @Test func effectiveWrongIdentityIsNotDisplayedAsSelectedAccount() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.client.setEffectiveAuth(.init(authMethod: "chatgpt", requiresOpenaiAuth: true,
                                                    identity: .init(accountID: "B", email: "b@example.test")))
        await fixture.backend.start()
        #expect(fixture.backend.officialIdentityAccountID == nil)
        #expect(fixture.backend.officialIdentityError?.contains("不一致") == true)
    }

    @Test func failedConfigurationRefreshClearsPreviouslyVerifiedIdentity() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        #expect(fixture.backend.officialIdentityAccountID != nil)
        try Data("model_provider = true\n".utf8).write(to: fixture.active.appending(path: "config.toml"))
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.effectiveAuthStatus == nil)
        #expect(fixture.backend.officialIdentityAccountID == nil)
        #expect(fixture.backend.officialIdentityError != nil)
    }

    @Test func backActionDispatchesTheWholeCopilotIdentityPair() async throws {
        let backend = MenuBackend.demo()
        await backend.start()
        let a = try #require(backend.accounts.first?.id)
        let b = try #require(backend.accounts.last?.id)
        await backend.selectCopilot(identity: a)
        await backend.selectChatGPT(b)
        await backend.switchBack()
        #expect(backend.selection == MenuSelection(provider: "copilot", accountID: a))
        #expect(backend.previousSelection == MenuSelection(provider: "openai", accountID: b))
    }
    @Test func mismatchedQuotaIsNeverPublishedOrCachedUnderOldAccount() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        let profile = try #require(backend.accounts.first)
        let old = WeeklyUsage(remainingPercent: 41, resetsAt: .distantFuture)
        try await backend.store.cacheWeeklyUsage(old, profileID: profile.id)
        await fixture.client.returnWrongAccount()
        await backend.refresh(force: true)
        #expect(backend.usageStates[profile.id]?.displayedUsage?.remainingPercent != 87)
        let cache = try await backend.store.loadUsageCache()
        #expect(cache.entries.first(where: { $0.profileID == profile.id })?.usage.remainingPercent == 41)
        #expect(backend.errorMessage?.contains("原生登录已变化") == true)
        #expect(backend.selection.accountID == nil)
    }

    @Test func nativeSourceChangesAreReadAgainOnRefresh() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        #expect(fixture.backend.selection.provider == "openai")
        try Data("model_provider = \"copilot\"\n".utf8).write(to: fixture.active.appending(path: "config.toml"))
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.selection.provider == "copilot")
        #expect(!fixture.backend.selection.officialIdentityDisabled)
    }

    @Test func failedRefreshKeepsTheSuccessfulDataTimestamp() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        try await fixture.backend.store.registerActiveIdentity(.init(accountID: "A", email: "a@example.test"))
        let id = try #require(try await fixture.backend.store.loadRegistry().accounts.first?.id)
        let yesterday = Date(timeIntervalSince1970: 1_650_000_000)
        try await fixture.backend.store.cacheWeeklyUsage(.init(remainingPercent: 41, resetsAt: .distantFuture), profileID: id, fetchedAt: yesterday)
        await fixture.backend.start()
        await fixture.client.failUsage()
        await fixture.backend.refresh(force: true)
        #expect(fixture.backend.usageFetchedAt[id] == yesterday)
        #expect(fixture.backend.usageStates[id]?.refreshError?.contains(yesterday.formatted(date: .abbreviated, time: .shortened)) == true)
        #expect(fixture.backend.usageStates[id]?.displayedUsage?.remainingPercent == 41)
    }

    @Test func quotaReaderHoldsTheSameLockAsAnotherSwitcher() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        await fixture.backend.start()
        await fixture.client.enableGate()
        let task = Task { await fixture.backend.refresh(force: true) }
        for _ in 0..<100 {
            if await fixture.client.enteredGate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.client.enteredGate)
        let desktop = CountedDesktop()
        let another = SourceSwitchService(store: AccountStore(baseURL: fixture.storage, activeHomeURL: fixture.active),
            codex: fixture.client, desktop: desktop, provider: ProviderConfiguration(codexHome: fixture.active))
        do { _ = try await another.switchSource(to: .copilot); Issue.record("Reading must exclude a concurrent switch") }
        catch { #expect(error as? SourceFileError != nil) }
        #expect(await desktop.closes == 0)
        await fixture.client.releaseGate()
        await task.value
    }

    @Test func demoMutationsStayInMemoryAndLoginCanBeCancelled() async throws {
        let backend = MenuBackend.demo()
        await backend.start()
        let originalCount = backend.accounts.count
        let id = try #require(backend.accounts.first?.id)
        await backend.selectChatGPT(id)
        #expect(backend.selection.accountID == id)
        await backend.rename(id, name: "只在演示中")
        #expect(backend.accounts.first?.displayName == "只在演示中")
        await backend.selectCopilot()
        let login = Task { await backend.addAccount() }
        for _ in 0..<50 {
            if backend.isAddingAccount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        backend.cancelLogin()
        await login.value
        #expect(!backend.isAddingAccount)
        #expect(backend.accounts.count == originalCount)
        #expect(backend.status.contains("取消"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/codex-menu-demo-unused/accounts.json"))
    }

    @Test func choosingSourceDuringQuotaRefreshWaitsThenSwitches() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        await fixture.client.enableGate()
        let refresh = Task { await backend.refresh(force: true) }
        for _ in 0..<100 {
            if await fixture.client.enteredGate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.client.enteredGate)
        #expect(!backend.isBusy)
        let selection = Task { await backend.selectCopilot() }
        for _ in 0..<100 {
            if backend.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.isBusy)
        #expect(backend.selection.provider == "openai")
        #expect(await fixture.desktop.closes == 0)
        await fixture.client.releaseGate()
        await refresh.value
        await selection.value
        #expect(!backend.isBusy)
        #expect(backend.selection.provider == "copilot")
        #expect(backend.previousSelection?.provider == "openai")
        #expect(await fixture.desktop.closes == 1)
        #expect(backend.errorMessage == nil)
    }

    @Test func renameDuringQuotaRefreshWaitsWithoutLosingTheRequest() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        let account = try #require(backend.accounts.first)
        await fixture.client.enableGate()
        let refresh = Task { await backend.refresh(force: true) }
        for _ in 0..<100 {
            if await fixture.client.enteredGate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.client.enteredGate)
        let rename = Task { await backend.rename(account.id, name: "我的账号") }
        for _ in 0..<100 {
            if backend.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.isBusy)
        #expect(backend.accounts.first?.displayName == account.displayName)
        await fixture.client.releaseGate()
        await refresh.value
        await rename.value
        #expect(!backend.isBusy)
        #expect(backend.accounts.first?.displayName == "我的账号")
        #expect(backend.errorMessage == nil)
    }

    @Test func cancellingQueuedLoginDoesNotWaitForQuotaNetworkOrStartLogin() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        await fixture.client.enableGate()
        let refresh = Task { await backend.refresh(force: true) }
        for _ in 0..<100 {
            if await fixture.client.enteredGate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.client.enteredGate)
        let login = Task { await backend.addAccount() }
        for _ in 0..<100 {
            if backend.isAddingAccount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.isAddingAccount)
        backend.cancelLogin()
        for _ in 0..<100 {
            if !backend.isAddingAccount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The quota gate is deliberately still closed here.
        #expect(!backend.isAddingAccount)
        #expect(await fixture.client.loginCalls == 0)
        #expect(backend.accounts.count == 1)
        await fixture.client.releaseGate()
        await refresh.value
        await login.value
    }

    @Test func quittingWaitsForCredentialReaderAndRejectsNewActions() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        await fixture.client.enableGate()
        let refresh = Task { await backend.refresh(force: true) }
        for _ in 0..<100 {
            if await fixture.client.enteredGate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.client.enteredGate)
        var readyToQuit = false
        let quit = Task { readyToQuit = await backend.prepareToQuit() }
        for _ in 0..<100 {
            if backend.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.isBusy)
        #expect(!readyToQuit)
        await backend.selectCopilot()
        #expect(await fixture.desktop.closes == 0)
        await fixture.client.releaseGate()
        await refresh.value
        await quit.value
        #expect(readyToQuit)
    }

    @Test func unrestoredSwitchPausesCredentialWorkUntilAnExplicitSwitchSucceeds() async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        let id = try #require(backend.accounts.first?.id)
        let auth = fixture.active.appending(path: "auth.json")
        let savedAuth = await backend.store.profileHome(id: id).appending(path: "auth.json")
        let savedBefore = try SourceFileSnapshot.read(savedAuth)
        var rotated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: Any])
        var tokens = try #require(rotated["tokens"] as? [String: String])
        tokens["refresh_token"] = "synthetic-partially-reopened-rotation"
        rotated["tokens"] = tokens
        let rotatedBytes = try JSONSerialization.data(withJSONObject: rotated)
        let originalHomeReads = await fixture.client.effectiveReads(at: fixture.active)
        await fixture.desktop.failNextReopen(blockingRecoveryClose: true, rotatingAuth: auth, to: rotatedBytes)

        // Exercise the real backend -> SourceSwitchService catch. The fake
        // Desktop rotates auth after commit, then refuses the recovery close.
        await backend.selectCopilot(identity: id)
        #expect(backend.errorMessage?.contains("could not be fully restored") == true)
        #expect(backend.officialIdentityAccountID == nil)
        #expect(await fixture.client.effectiveReads(at: fixture.active) == originalHomeReads)
        try savedBefore.requireUnchanged()
        #expect(try Data(contentsOf: auth) == rotatedBytes)
        let heldFiles = try [auth, savedAuth, fixture.active.appending(path: "config.toml"),
            fixture.storage.appending(path: "accounts.json"), fixture.storage.appending(path: "previous-source.json")]
            .map { try SourceFileSnapshot.read($0) }
        let heldCalls = await fixture.client.callCounts()
        await backend.refresh()
        await backend.refresh(force: true)
        await backend.importCurrentAccount()
        await backend.start()
        backend.dismissError()
        await backend.refresh(force: true)
        #expect(backend.errorMessage?.contains("could not be fully restored") == true)
        #expect(await fixture.client.callCounts() == heldCalls)
        #expect(backend.lastRefreshedAt == nil)

        // A new, unchanged preflight failure must not acknowledge the earlier
        // unsafe state or restart the helper in its own catch path.
        await backend.selectChatGPT(UUID())
        #expect(backend.errorMessage?.contains("could not be fully restored") == true)
        await backend.refresh(force: true)
        #expect(await fixture.client.callCounts() == heldCalls)
        for file in heldFiles { try file.requireUnchanged() }

        await fixture.desktop.clearFailures()
        await backend.selectChatGPT(id)
        #expect(backend.errorMessage == nil)
        #expect(backend.officialIdentityAccountID == id)
        #expect(await fixture.client.effectiveReads(at: fixture.active) == originalHomeReads + 1)
        #expect(try Data(contentsOf: savedAuth) == rotatedBytes)
        await backend.refresh(force: true)
        #expect(backend.lastRefreshedAt != nil)
        #expect(await fixture.client.callCounts() != heldCalls)
    }

    @Test(arguments: [false, true])
    func unchangedAndRestoredFailuresKeepNormalRefreshAvailable(mutatedBeforeFailure: Bool) async throws {
        let fixture = try BackendFixture()
        defer { fixture.clean() }
        let backend = fixture.backend
        await backend.start()
        let id = try #require(backend.accounts.first?.id)
        if mutatedBeforeFailure {
            await fixture.desktop.failNextReopen(blockingRecoveryClose: false)
            await backend.selectCopilot(identity: id)
        } else {
            await backend.selectChatGPT(UUID())
        }
        #expect(backend.errorMessage != nil)
        #expect(backend.officialIdentityAccountID == id)
        await backend.refresh(force: true)
        #expect(backend.lastRefreshedAt != nil)
        #expect(backend.usageStates[id]?.displayedUsage != nil)
    }
}

private struct BackendFixture {
    let root: URL
    let active: URL
    let storage: URL
    let client: BoundUsageClient
    let desktop: CountedDesktop
    @MainActor let backend: MenuBackend

    @MainActor init(managedRelay: Bool = false, relay: (any APIRelayControlling)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "menu-backend-test-\(UUID())")
        active = root.appending(path: "active")
        storage = root.appending(path: "store")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let auth: [String: Any] = ["auth_mode": "chatgpt", "tokens": [
            "account_id": "A", "id_token": syntheticIDToken(email: "a@example.test", accountID: "A"), "access_token": "synthetic-access-A", "refresh_token": "synthetic-refresh-A"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: active.appending(path: "auth.json"))
        try Data("model_provider = \"openai\"\n[model_providers.copilot]\nname = \"Copilot\"\nbase_url = \"http://127.0.0.1:4141/v1\"\nwire_api = \"responses\"\n".utf8).write(to: active.appending(path: "config.toml"))
        client = BoundUsageClient()
        desktop = CountedDesktop()
        let usageClient = client
        backend = MenuBackend(storageURL: storage, activeHome: active, desktop: desktop, codex: client,
            relay: relay ?? (managedRelay ? BackendRelay() : nil),
            copilotFetcher: { try await usageClient.readCopilotUsage() })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private actor BoundUsageClient: AccountClient {
    private var identityCalls = 0, usageCalls = 0, copilotCalls = 0
    private var effectiveHomes: [URL] = []
    func callCounts() -> [Int] { [identityCalls, effectiveHomes.count, usageCalls, loginCalls, copilotCalls] }
    func effectiveReads(at home: URL) -> Int { effectiveHomes.filter { $0 == home }.count }
    func readCopilotUsage() throws -> CopilotSnapshot { copilotCalls += 1; throw CodexClientError.connectionClosed }
    var effective = EffectiveAuthStatus(authMethod: "chatgpt", requiresOpenaiAuth: true,
                                        identity: .init(accountID: "A", email: "a@example.test"))
    func setEffectiveAuth(_ value: EffectiveAuthStatus) { effective = value }
    func readEffectiveAuthStatus(profileHome: URL) async throws -> EffectiveAuthStatus {
        effectiveHomes.append(profileHome)
        let route = try await ProviderConfiguration(codexHome: profileHome).readRoute()
        if route.isManaged && route.physicalProvider == "copilot" {
            return .init(authMethod: nil, requiresOpenaiAuth: false, identity: nil)
        }
        return effective
    }
    var verificationCalls = 0
    func verifyIdentity(profileHome: URL) async throws -> AccountIdentity {
        verificationCalls += 1
        return try await readIdentity(profileHome: profileHome)
    }
    var wrong = false
    var fails = false
    var gated = false
    var enteredGate = false
    var loginCalls = 0
    var identityFailsOnce = false
    var continuation: CheckedContinuation<Void, Never>?
    func returnWrongAccount() { wrong = true }
    func failUsage() { fails = true }
    func failNextIdentityRead() { identityFailsOnce = true }
    func enableGate() { gated = true }
    func releaseGate() { continuation?.resume(); continuation = nil }
    func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        identityCalls += 1
        if identityFailsOnce { identityFailsOnce = false; throw CodexClientError.timeout }
        return .init(accountID: "A", email: "a@example.test")
    }
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage { .init(remainingPercent: 33, resetsAt: .distantFuture) }
    func readAccountUsage(profileHome: URL) async throws -> AccountUsage {
        usageCalls += 1
        if fails { throw CodexClientError.timeout }
        if gated {
            enteredGate = true
            await withCheckedContinuation { continuation = $0 }
        }
        return AccountUsage(identity: .init(accountID: wrong ? "B" : "A", email: wrong ? "b@example.test" : "a@example.test"),
            usage: .init(remainingPercent: wrong ? 87 : 33, resetsAt: .distantFuture))
    }
    func login(profileHome: URL) async throws -> AccountIdentity {
        loginCalls += 1
        throw CodexClientError.loginFailed("disabled in test")
    }
}

private actor CountedDesktop: DesktopControlling {
    var closes = 0, reopens = 0
    var stopped = false
    private var failingCloses: Set<Int> = [], failingReopens: Set<Int> = []
    private var rotation: (URL, Data)?
    func failNextReopen(blockingRecoveryClose: Bool, rotatingAuth: URL? = nil, to bytes: Data? = nil) {
        failingReopens.insert(reopens + 1)
        if blockingRecoveryClose { failingCloses.insert(closes + 2) }
        if let rotatingAuth, let bytes { rotation = (rotatingAuth, bytes) }
    }
    func clearFailures() { failingCloses = []; failingReopens = []; rotation = nil }
    func closeDesktop() async throws {
        closes += 1
        if failingCloses.contains(closes) { throw DesktopControlError.terminationRefused }
        stopped = true
    }
    func reopenDesktop() async throws {
        reopens += 1
        stopped = false
        if failingReopens.contains(reopens) {
            if let (url, bytes) = rotation { try bytes.write(to: url, options: .atomic) }
            throw DesktopControlError.launchFailed
        }
    }
    func isDesktopStopped() async throws -> Bool { stopped }
}

private actor BackendRelay: APIRelayControlling {
    private var enabled = false
    func status() async throws -> APIRelayStatus? { value() }
    func ensureRunning() async throws -> APIRelayStatus { value() }
    func setEnabled(_ enabled: Bool) async throws -> APIRelayStatus {
        self.enabled = enabled
        return value()
    }
    private func value() -> APIRelayStatus {
        APIRelayStatus(protocolVersion: 1, pid: 123, instanceId: "backend-fixture", host: "127.0.0.1", port: 4142,
            baseURL: "http://127.0.0.1:4142/v1", enabled: enabled, activeRequests: 0, activeWebSockets: 0,
            testMode: true, upstreamPort: 4141)
    }
}

private actor RecoveringBackendRelay: APIRelayControlling {
    private var running: Bool, enabled: Bool
    private var startupFailures: Int
    private let activeRequests: Int
    private var starts = 0, enableCalls = 0
    private var expectedHome: URL?

    init(startupFailures: Int = 0, running: Bool = false, enabled: Bool = false, activeRequests: Int = 0) {
        self.startupFailures = startupFailures
        self.running = running; self.enabled = enabled; self.activeRequests = activeRequests
    }
    func expectSourceLock(at home: URL) { expectedHome = home }
    func mutationCounts() -> [Int] { [starts, enableCalls] }
    func isEnabled() -> Bool { enabled }
    func status() throws -> APIRelayStatus? {
        try requireSourceLock()
        return running ? value() : nil
    }
    func ensureRunning() throws -> APIRelayStatus {
        try requireSourceLock()
        starts += 1
        if startupFailures > 0 {
            startupFailures -= 1
            throw APIRelayError.unavailable("synthetic startup failure")
        }
        running = true
        return value()
    }
    func setEnabled(_ enabled: Bool) throws -> APIRelayStatus {
        try requireSourceLock()
        enableCalls += 1
        self.enabled = enabled
        return value()
    }
    private func requireSourceLock() throws {
        guard let expectedHome else { return }
        do {
            let unexpected = try SourceSwitchLock(home: expectedHome)
            unexpected.release()
            Issue.record("Relay recovery must hold the source switch lock")
        } catch SourceFileError.busy { }
    }
    private func value() -> APIRelayStatus {
        APIRelayStatus(protocolVersion: 1, pid: 123, instanceId: "recovering-backend-fixture", host: "127.0.0.1", port: 4142,
            baseURL: "http://127.0.0.1:4142/v1", enabled: enabled, activeRequests: activeRequests, activeWebSockets: 0,
            testMode: true, upstreamPort: 4141)
    }
}
