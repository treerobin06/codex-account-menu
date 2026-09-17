import Foundation
import Testing
@testable import SwitcherCore

@MainActor
struct LaunchAtLoginTests {
    @Test func statusAlwaysReadsTheSystemAndOnlyEnabledCountsAsOn() {
        let adapter = LoginItemFake()
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        for state: LaunchAtLoginStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unavailable] {
            adapter.status = state
            #expect(service.status == state)
            #expect((service.status == .enabled) == (state == .enabled))
        }
        #expect(adapter.calls.isEmpty)
    }

    @Test func registrationFailureDoesNotReportEnabledAndCanRetry() async throws {
        let adapter = LoginItemFake()
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        adapter.failRegister = true
        await #expect(throws: LoginItemTestError.self) { try await service.setEnabled(true) }
        #expect(service.status == .notRegistered)
        adapter.failRegister = false
        try await service.setEnabled(true)
        #expect(service.status == .enabled)
        #expect(adapter.calls == ["register", "register"])
    }

    @Test func failedUnregisterDoesNotReportDisabled() async {
        let adapter = LoginItemFake(status: .enabled)
        adapter.failUnregister = true
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        await #expect(throws: LoginItemTestError.self) { try await service.setEnabled(false) }
        #expect(service.status == .enabled)
        #expect(adapter.calls == ["unregister"])
    }

    @Test func pendingApprovalRemainsSeparateAndDoesNotReregister() async throws {
        let adapter = LoginItemFake()
        adapter.registeredStatus = .requiresApproval
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        try await service.setEnabled(true)
        #expect(service.status == .requiresApproval)
        try await service.setEnabled(true)
        #expect(adapter.calls == ["register"])
        service.openSystemSettings()
        #expect(adapter.calls == ["register", "settings"])
        try await service.setEnabled(false)
        #expect(service.status == .notRegistered)
    }

    @Test func repeatedEnableAndDisableAreIdempotentAndDoNotQuitTheApp() async throws {
        let adapter = LoginItemFake()
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        try await service.setEnabled(false)
        try await service.setEnabled(true)
        try await service.setEnabled(true)
        try await service.setEnabled(false)
        try await service.setEnabled(false)
        #expect(adapter.calls == ["register", "unregister"])
        #expect(service.status == .notRegistered)
        // The only adapter operation for disabling is unregistering mainApp;
        // there is no application-lifecycle or helper termination dependency.
    }

    @Test func enableCannotRaceAnUnregisterStillAwaitingTheSystem() async throws {
        let adapter = LoginItemFake(status: .enabled)
        adapter.holdUnregister = true
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        let disabling = Task { try await service.setEnabled(false) }
        defer { adapter.resumeUnregister() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while adapter.unregisterContinuation == nil && ContinuousClock.now < deadline { await Task.yield() }
        _ = try #require(adapter.unregisterContinuation)
        await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(true) }
        #expect(adapter.calls == ["unregister"])
        adapter.resumeUnregister()
        try await disabling.value
        try await service.setEnabled(true)
        #expect(service.status == .enabled)
        #expect(adapter.calls == ["unregister", "register"])
    }

    @Test(arguments: [false, true])
    func successfulCallbackWithoutSystemChangeIsNotReportedAsSuccess(enabling: Bool) async {
        let adapter = LoginItemFake(status: enabling ? .notRegistered : .enabled)
        adapter.preserveStatus = true
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(enabling) }
        #expect(service.status == (enabling ? .notRegistered : .enabled))
    }

    @Test func unavailableSystemStateNeverAttemptsRegistration() async {
        let adapter = LoginItemFake(status: .unavailable)
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(true) }
        await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(false) }
        #expect(service.status == .unavailable)
        #expect(adapter.calls.isEmpty)
    }

    @Test func missingMainAppRecordCanRegisterButNeverPretendsSuccess() async throws {
        let adapter = LoginItemFake(status: .notFound)
        let service = LaunchAtLoginService(adapter: adapter, host: productionHost())
        adapter.failRegister = true
        await #expect(throws: LoginItemTestError.self) { try await service.setEnabled(true) }
        #expect(service.status == .notFound)
        adapter.failRegister = false
        adapter.preserveStatus = true
        await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(true) }
        #expect(service.status == .notFound)
        adapter.preserveStatus = false
        try await service.setEnabled(true)
        #expect(service.status == .enabled)
        #expect(adapter.calls == ["register", "register", "register"])
    }

    @Test func onlyTheProductionMainAppMayUseTheSystemAdapter() async {
        let supported = productionHost()
        #expect(supported.isSupported)
        var variants: [LaunchAtLoginHost] = []
        var host = supported; host.bundleIdentifier = "com.tree.codex-account-menu.demo"; variants.append(host)
        host = supported; host.bundleIdentifier = nil; variants.append(host)
        host = supported; host.isDemoBundle = true; variants.append(host)
        host = supported; host.isDemoBundle = nil; variants.append(host)
        host = supported; host.isDemoMode = true; variants.append(host)
        host = supported; host.packageType = "BNDL"; variants.append(host)
        host = supported; host.declaredExecutable = "codex-menu"; variants.append(host)
        host = supported; host.executableURL = supported.bundleURL.appending(path: "Contents/Helpers/codex-menu"); variants.append(host)
        host = supported; host.executableURL = nil; variants.append(host)
        host = supported; host.bundleURL = URL(fileURLWithPath: "/tmp/.build/release"); variants.append(host)
        for host in variants {
            let adapter = LoginItemFake(status: .enabled)
            let service = LaunchAtLoginService(adapter: adapter, host: host)
            #expect(service.status == .unavailable)
            await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(true) }
            await #expect(throws: LaunchAtLoginError.self) { try await service.setEnabled(false) }
            service.openSystemSettings()
            #expect(adapter.calls.isEmpty)
        }
    }

    @Test func productionInitializerIsUnavailableInTheTestExecutable() {
        #expect(LaunchAtLoginService().status == .unavailable)
    }
}

private func productionHost() -> LaunchAtLoginHost {
    let app = URL(fileURLWithPath: "/tmp/login-item-fixture/Codex Account Menu.app")
    return LaunchAtLoginHost(bundleURL: app, bundleIdentifier: "com.tree.codex-account-menu",
        packageType: "APPL", declaredExecutable: "CodexAccountMenu",
        executableURL: app.appending(path: "Contents/MacOS/CodexAccountMenu"),
        isDemoBundle: false, isDemoMode: false)
}

private enum LoginItemTestError: Error { case injected }

@MainActor
private final class LoginItemFake: LaunchAtLoginSystemAdapting {
    var status: LaunchAtLoginStatus
    var registeredStatus = LaunchAtLoginStatus.enabled
    var failRegister = false, failUnregister = false, preserveStatus = false
    var holdUnregister = false
    var unregisterContinuation: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    init(status: LaunchAtLoginStatus = .notRegistered) { self.status = status }
    func register() throws {
        calls.append("register")
        if failRegister { throw LoginItemTestError.injected }
        if !preserveStatus { status = registeredStatus }
    }
    func unregister() async throws {
        calls.append("unregister")
        if failUnregister { throw LoginItemTestError.injected }
        if holdUnregister { await withCheckedContinuation { unregisterContinuation = $0 } }
        if !preserveStatus { status = .notRegistered }
    }
    func resumeUnregister() {
        unregisterContinuation?.resume()
        unregisterContinuation = nil
    }
    func openSystemSettings() { calls.append("settings") }
}
