import Foundation
import Testing
@testable import SwitcherCore

private let fixtureExecutable = ProcessInfo.processInfo.environment["SWITCHER_TEST_RPC_EXE"]

@Suite(.enabled(if: fixtureExecutable != nil))
struct CodexClientTransportTests {
    @Test(arguments: ["managed-route-api-good", "managed-route-native-good",
                      "managed-route-api-wrong-provider", "managed-route-api-wrong-base", "managed-route-native-wrong-base"])
    func managedRouteChecksResolvedConfigurationBeforeTrustingAuthentication(_ mode: String) async throws {
        let home = try fixtureHome(mode)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("model_provider='openai'\n[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\n".utf8).write(to: home.appending(path: "config.toml"))
        let provider = ProviderConfiguration(codexHome: home)
        _ = try await provider.setRoute(mode.contains("native") ? "openai" : "copilot",
            hasOfficialIdentity: true, expecting: provider.snapshot())
        // The account-only forced OpenAI read succeeds in every case. It must
        // never mask an effective route mismatch in the separate check.
        #expect(try await makeClient().readIdentity(profileHome: home).accountID == "fixture")
        if mode.contains("wrong") {
            await #expect(throws: SourceFileError.self) { _ = try await makeClient().readEffectiveAuthStatus(profileHome: home) }
            let events = try fixtureEvents(home)
            let effective = try #require(events.last { $0.event == "launch" })
            #expect(!events.contains { $0.pid == effective.pid && $0.method == "getAuthStatus" })
        } else {
            #expect(try await makeClient().readEffectiveAuthStatus(profileHome: home).authMethod == "chatgpt")
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_TEST_INSTALLED_CLI"] != nil))
    func installedCliUsesOnlyAnIsolatedEmptyHome() async throws {
        let home = try fixtureHome("installed-cli")
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        let client = CodexClient(locator: .init(explicitURL: URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["SWITCHER_TEST_INSTALLED_CLI"]!)))
        do { _ = try await client.readIdentity(profileHome: home); Issue.record("An isolated home must not have a login.") }
        catch { #expect(error as? CodexClientError == .identityUnavailable) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func parsesIdentityAndBothUsageWindows() async throws {
        let home = try fixtureHome("normal")
        defer { try? FileManager.default.removeItem(at: home) }
        let client = makeClient()
        let identity = try await client.readIdentity(profileHome: home)
        #expect(identity.accountID == "fixture")
        let usage = try await client.readWeeklyUsage(profileHome: home)
        #expect(usage.remainingPercent == 42)
        #expect(usage.fiveHourRemainingPercent == 67)
    }

    @Test func quotaResultIncludesVerifiedAccountBinding() async throws {
        let home = try fixtureHome("normal")
        defer { try? FileManager.default.removeItem(at: home) }
        let reading = try await makeClient().readAccountUsage(profileHome: home)
        #expect(reading.identity.accountID == "fixture")
        #expect(reading.usage.remainingPercent == 42)
    }

    @Test(arguments: ["identity-quota-id-conflict", "identity-user-changed", "identity-quota-empty-id"])
    func bothQuotaReadersRejectConflictingOrIncompleteIdentity(_ mode: String) async throws {
        for verifiesOnly in [true, false] {
            let home = try fixtureHome(mode)
            defer { try? FileManager.default.removeItem(at: home) }
            do {
                if verifiesOnly { _ = try await makeClient().verifyIdentity(profileHome: home) }
                else { _ = try await makeClient().readAccountUsage(profileHome: home) }
                Issue.record("A conflicting quota and identity must not be combined")
            } catch {
                if mode == "identity-quota-empty-id" {
                    #expect(error as? CodexClientError == .identityUnavailable)
                } else {
                    #expect(error as? AccountStoreError == .activeCredentialMismatch)
                }
            }
        }
    }

    @Test(arguments: ["effective-email-only-switch-user", "effective-email-only-switch-workspace"])
    func effectiveQuotaIDCannotBeCombinedWithAnotherIdentity(_ mode: String) async throws {
        let home = try fixtureHome(mode)
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: AccountStoreError.self) {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        }
    }

    @Test(arguments: ["identity-missing-email", "identity-empty-email", "identity-email-disappears"])
    func incompleteUserIdentityIsNeverConfirmedOrBoundToQuota(_ mode: String) async throws {
        for operation in 0..<3 {
            if mode == "identity-email-disappears" && operation == 2 { continue }
            let home = try fixtureHome(mode)
            defer { try? FileManager.default.removeItem(at: home) }
            await #expect(throws: CodexClientError.identityUnavailable) {
                let client = makeClient()
                if operation == 0 { _ = try await client.verifyIdentity(profileHome: home) }
                else if operation == 1 { _ = try await client.readAccountUsage(profileHome: home) }
                else { _ = try await client.readEffectiveAuthStatus(profileHome: home) }
            }
        }
    }

    @Test func schemaPermittedMissingAccountIsReportedAsDisconnected() async throws {
        let home = try fixtureHome("effective-account-omitted")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        #expect(status.identity == nil && status.authMethod == nil)
        #expect(status.requiresOpenaiAuth)
    }

    @Test func effectiveAuthUsesUnmodifiedConfigAndOneRuntimeWithoutRequestingTokens() async throws {
        let home = try fixtureHome("normal")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = Data("model_provider = \"copilot\"\ncli_auth_credentials_store = \"auto\"\n[mcp_servers.fixture]\ncommand = \"untouched\"\n".utf8)
        let configURL = home.appendingPathComponent("config.toml")
        try config.write(to: configURL)
        let client = makeClient()
        _ = try await client.readAccountUsage(profileHome: home)
        let status = try await client.readEffectiveAuthStatus(profileHome: home)
        #expect(status.authMethod == "chatgpt")
        #expect(status.requiresOpenaiAuth)
        #expect(status.identity?.accountID == "fixture")
        #expect(try Data(contentsOf: configURL) == config)

        let events = try fixtureEvents(home)
        let launches = events.filter { $0.event == "launch" }
        #expect(launches.count == 2)
        let native = try #require(launches.first)
        let effective = try #require(launches.last)
        #expect(native.arguments == ["-c", "model_provider=\"openai\"", "-c", "cli_auth_credentials_store=\"file\"", "app-server", "--listen", "stdio://"])
        #expect(effective.arguments == ["app-server", "--listen", "stdio://"])
        #expect(native.environmentKeys == [])
        #expect(effective.environmentKeys == [])
        let requests = events.filter { $0.pid == effective.pid && $0.event == "request" }
        #expect(requests.compactMap(\.method) == ["initialize", "initialized", "config/read", "getAuthStatus", "account/read"])
        let authRequest = try #require(requests.first { $0.method == "getAuthStatus" })
        let accountRequest = try #require(requests.first { $0.method == "account/read" })
        #expect(authRequest.includeToken == false)
        #expect(accountRequest.refreshToken == false)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test(arguments: ["effective-config-read-failed", "effective-legacy-auth-conflict"])
    func invalidConfigCannotBeReportedAsTheDefaultConnectedIdentity(_ mode: String) async throws {
        let home = try fixtureHome(mode)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = Data("model_provider='copilot'\n[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\nrequires_openai_auth=true\nexperimental_bearer_token='local'\n[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['local']\n".utf8)
        let configURL = home.appendingPathComponent("config.toml")
        try config.write(to: configURL)
        do {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
            Issue.record("Invalid config must not return the runtime's default connected identity.")
        } catch {
            let expected = mode == "effective-legacy-auth-conflict"
                ? "invalid configuration: provider auth cannot be combined with experimental_bearer_token, requires_openai_auth"
                : "fixture invalid configuration"
            #expect(error as? CodexClientError == .remoteError(code: -32603, message: expected))
        }
        let events = try fixtureEvents(home)
        let launches = events.filter { $0.event == "launch" }
        #expect(launches.count == 1)
        let pid = try #require(launches.first?.pid)
        let requests = events.filter { $0.event == "request" }
        #expect(requests.allSatisfy { $0.pid == pid })
        #expect(requests.compactMap(\.method) == ["initialize", "initialized", "config/read"])
        #expect(try Data(contentsOf: configURL) == config)
    }

    @Test func effectiveAuthRejectsAConfigReadSuccessWithoutAConfigObject() async throws {
        let home = try fixtureHome("effective-config-read-malformed")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
            Issue.record("A malformed config/read response cannot establish a valid runtime.")
        } catch { #expect(error as? CodexClientError == .malformedResponse) }
        #expect(try fixtureEvents(home).filter { $0.event == "request" }.compactMap(\.method)
            == ["initialize", "initialized", "config/read"])
    }

    @Test func effectiveAuthRequirementsDoNotFabricateALogin() async throws {
        let home = try fixtureHome("effective-no-auth")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        #expect(!status.requiresOpenaiAuth)
        #expect(status.authMethod == nil)
        #expect(status.identity == nil)
        #expect(!(try fixtureEvents(home)).contains { $0.method == "account/rateLimits/read" })
    }

    @Test func effectiveAuthPreservesAConcreteMismatchingWorkspace() async throws {
        let home = try fixtureHome("effective-identity-mismatch")
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = AccountProfile(id: UUID(), displayName: "Expected", email: "fixture@example.test",
            accountID: "fixture", createdAt: Date())
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        let identity = try #require(status.identity)
        #expect(identity.accountID == "other-workspace")
        #expect(!identity.matches(expected))
    }

    @Test func effectiveAuthNeverExposesAnUnexpectedTokenResponse() async throws {
        let home = try fixtureHome("effective-token-response")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        #expect(Set(Mirror(reflecting: status).children.compactMap(\.label)) == ["authMethod", "requiresOpenaiAuth", "identity"])
        #expect(!String(reflecting: status).contains("fixture-secret-must-never-escape"))
        let request = try #require(try fixtureEvents(home).first { $0.method == "getAuthStatus" })
        #expect(request.includeToken == false)
    }

    @Test func effectiveAuthRejectsInconsistentRequirements() async throws {
        let home = try fixtureHome("effective-inconsistent")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
            Issue.record("Conflicting effective auth observations must not be accepted.")
        } catch { #expect(error as? EffectiveAuthStatusError == .inconsistentState) }
    }

    @Test func effectiveAuthRequiresAnExplicitRequirementField() async throws {
        let home = try fixtureHome("effective-missing-requirement")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
            Issue.record("A missing requirement cannot default to authenticated.")
        } catch { #expect(error as? CodexClientError == .malformedResponse) }
    }

    @Test func effectiveAuthGetsAMissingWorkspaceIDFromTheSameRuntime() async throws {
        let home = try fixtureHome("effective-email-only")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        #expect(status.identity?.accountID == "fixture")
        #expect(status.identity?.email == "fixture@example.test")
        let events = try fixtureEvents(home)
        #expect(events.filter { $0.event == "launch" }.count == 1)
        #expect(events.filter { $0.event == "request" }.compactMap(\.method) == [
            "initialize", "initialized", "config/read", "getAuthStatus", "account/read", "account/rateLimits/read", "account/read",
        ])
    }

    @Test func effectiveAuthDoesNotInferAMissingWorkspaceIDFromLocalCredentials() async throws {
        let home = try fixtureHome("effective-email-only-no-id")
        defer { try? FileManager.default.removeItem(at: home) }
        let claims = Data(#"{"email":"fixture@example.test"}"#.utf8).base64EncodedString()
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": [
            "account_id": "local-workspace-must-not-be-inferred", "id_token": "header.\(claims).signature",
        ]])
        let authURL = home.appendingPathComponent("auth.json")
        try auth.write(to: authURL)
        let status = try await makeClient().readEffectiveAuthStatus(profileHome: home)
        #expect(status.identity?.accountID == nil)
        #expect(status.identity?.email == "fixture@example.test")
        #expect(try Data(contentsOf: authURL) == auth)
    }

    @Test func effectiveAuthPropagatesARequiredIdentityProbeFailure() async throws {
        let home = try fixtureHome("effective-email-only-error")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await makeClient().readEffectiveAuthStatus(profileHome: home)
            Issue.record("An upstream failure cannot become an authenticated result.")
        } catch {
            #expect(error as? CodexClientError == .remoteError(code: 401, message: "fixture authorization failed"))
        }
    }

    @Test func inheritedCredentialPollutionIsRemovedWithoutOverridingOtherEnvironment() {
        let home = URL(fileURLWithPath: "/tmp/isolated-effective-auth-home")
        var inherited = Dictionary(uniqueKeysWithValues: AccountRPCConfiguration.contaminatingEnvironmentKeys.map { ($0, "synthetic-secret") })
        inherited["CODEX_HOME"] = "/tmp/wrong-home"
        inherited["HTTPS_PROXY"] = "http://127.0.0.1:7897"
        inherited["UNRELATED_SETTING"] = "preserved"
        let cleaned = AccountRPCConfiguration.environment(inherited, profileHome: home)
        #expect(AccountRPCConfiguration.contaminatingEnvironmentKeys.allSatisfy { cleaned[$0] == nil })
        #expect(cleaned["CODEX_HOME"] == home.path)
        #expect(cleaned["HTTPS_PROXY"] == inherited["HTTPS_PROXY"])
        #expect(cleaned["UNRELATED_SETTING"] == "preserved")
    }

    @Test func aLegacyMockCannotSilentlyPassEffectiveAuthVerification() async throws {
        do {
            _ = try await LegacyAccountClient().readEffectiveAuthStatus(profileHome: URL(fileURLWithPath: "/tmp/unused-legacy-client-home"))
            Issue.record("The default protocol implementation must explicitly reject this operation.")
        } catch { #expect(error as? EffectiveAuthStatusError == .notSupported) }
    }

    @Test func helperHasReallyExitedBeforeReadReturns() async throws {
        let home = try fixtureHome("slow-exit")
        defer { try? FileManager.default.removeItem(at: home) }
        let started = Date()
        _ = try await makeClient().readIdentity(profileHome: home)
        #expect(Date().timeIntervalSince(started) >= 0.30)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("exit-write-completed").path))
    }

    @Test func helperEOFBeforeInitializeResponseIsAClosedConnectionNotATimeout() async throws {
        let home = try fixtureHome("early-eof")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await makeClient().readIdentity(profileHome: home)
            Issue.record("An exited helper cannot supply an identity.")
        } catch { #expect(error as? CodexClientError == .connectionClosed) }
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("early-exit-completed").path))
    }

    @Test func loginAcceptsCompletionBeforeStartResponse() async throws {
        let home = try fixtureHome("login")
        defer { try? FileManager.default.removeItem(at: home) }
        let client = makeClient()
        let identity = try await client.login(profileHome: home)
        #expect(identity.email == "fixture@example.test")
    }

    @Test func aSilentServerTimesOut() async throws {
        let home = try fixtureHome("timeout")
        defer { try? FileManager.default.removeItem(at: home) }
        let client = makeClient(timeout: .milliseconds(500))
        do {
            _ = try await client.readIdentity(profileHome: home)
            Issue.record("Expected a timeout")
        } catch { #expect(error as? CodexClientError == .timeout) }
    }

    @Test func pendingLoginCanBeCancelled() async throws {
        let home = try fixtureHome("cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let signal = BrowserSignal()
        let client = CodexClient(locator: .init(explicitURL: URL(fileURLWithPath: fixtureExecutable!)),
            openBrowser: { _ in await signal.opened() })
        let task = Task { try await client.login(profileHome: home) }
        for _ in 0..<100 {
            if await signal.isOpen { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await signal.isOpen)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    private func makeClient(timeout: Duration = .seconds(5)) -> CodexClient {
        CodexClient(locator: .init(explicitURL: URL(fileURLWithPath: fixtureExecutable!)), requestTimeout: timeout,
            openBrowser: { url in #expect(url.host == "example.test") })
    }
    private func fixtureHome(_ scenario: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-rpc-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(scenario.utf8).write(to: home.appendingPathComponent("fixture-mode"))
        return home
    }

    private func fixtureEvents(_ home: URL) throws -> [RPCFixtureEvent] {
        let data = try Data(contentsOf: home.appendingPathComponent("fixture-events.jsonl"))
        return try data.split(separator: 0x0A).map { try JSONDecoder().decode(RPCFixtureEvent.self, from: Data($0)) }
    }
}

@Suite
struct LinePumpEOFTests {
    @Test(arguments: ["", "final response without newline"])
    func eofDisablesTheHandlerAndPreservesTheLastBufferedLine(finalChunk: String) async throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        let pump = LinePump(handle: reader)
        defer {
            // Cleanup also prevents the old bug from spinning after a failing assertion.
            reader.readabilityHandler = nil
            try? reader.close()
            try? writer.close()
        }
        if !finalChunk.isEmpty { try writer.write(contentsOf: Data(finalChunk.utf8)) }
        try writer.close()
        let expected: Data? = finalChunk.isEmpty ? nil : Data(finalChunk.utf8)
        #expect(try await pump.next() == expected)
        #expect(reader.readabilityHandler == nil)
        #expect(try await pump.next() == nil)
    }

    @Test func releasedPumpUnregistersItsRemainingReadCallback() async throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        var pump: LinePump? = LinePump(handle: reader)
        weak var releasedPump = pump
        defer {
            reader.readabilityHandler = nil
            try? reader.close()
            try? writer.close()
        }
        pump = nil
        #expect(releasedPump == nil)
        try writer.write(contentsOf: Data("ready".utf8))
        for _ in 0..<100 {
            if reader.readabilityHandler == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.readabilityHandler == nil)
    }
}

private struct RPCFixtureEvent: Decodable {
    let event: String
    let pid: Int
    let arguments: [String]?
    let environmentKeys: [String]?
    let method: String?
    let includeToken: Bool?
    let refreshToken: Bool?
}

private struct LegacyAccountClient: AccountClient {
    func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        AccountIdentity(accountID: "legacy", email: "legacy@example.test")
    }
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage {
        WeeklyUsage(remainingPercent: 100, resetsAt: Date())
    }
    func login(profileHome: URL) async throws -> AccountIdentity {
        try await readIdentity(profileHome: profileHome)
    }
}

private actor BrowserSignal {
    var isOpen = false
    func opened() { isOpen = true }
}
