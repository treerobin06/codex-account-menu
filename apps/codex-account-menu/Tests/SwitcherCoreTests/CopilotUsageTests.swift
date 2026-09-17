import Foundation
import Testing
@testable import SwitcherCore

struct CopilotUsageTests {
    private let fixture = """
    {
      "observedAt": "2026-09-16T08:30:15.123Z",
      "login": "fixture-user",
      "plan": "enterprise",
      "remainingPercent": 96.6,
      "resetsAt": "2026-10-01T00:00:00Z",
      "tokenBasedBilling": true,
      "overagePermitted": true,
      "modelsAvailable": null,
      "ignoredSecret": "DO_NOT_LEAK_FIXTURE_SECRET"
    }
    """

    @Test func mixedTimestampFormatsAndExactPercentage() throws {
        let value = try CopilotUsageService.decodeOutput(Data(fixture.utf8), exitCode: 0)
        #expect(value.login == "fixture-user")
        #expect(value.plan == "enterprise")
        #expect(value.remainingPercent == 96.6)
        #expect(value.tokenBasedBilling)
        #expect(value.overagePermitted)
        #expect(value.modelsAvailable == nil)
        #expect(abs(value.observedAt.timeIntervalSince1970 - 1_789_547_415.123) < 0.001)
        let reset = try #require(value.resetsAt)
        #expect(reset.timeIntervalSince1970 == 1_790_812_800)
    }

    @Test func encodingProducesOnlyWhitelistedFieldsAndISO8601() throws {
        let value = try CopilotUsageService.decodeOutput(Data(fixture.utf8), exitCode: 0)
        let encoded = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "observedAt", "login", "plan", "remainingPercent", "resetsAt",
            "tokenBasedBilling", "overagePermitted", "modelsAvailable",
        ]))
        #expect(object["resetsAt"] as? String == "2026-10-01T00:00:00.000Z")
        #expect(!String(decoding: encoded, as: UTF8.self).contains("DO_NOT_LEAK_FIXTURE_SECRET"))
        #expect(try JSONDecoder().decode(CopilotSnapshot.self, from: encoded) == value)
    }

    @Test func unknownQuotaAndResetStayNil() throws {
        let data = fixture
            .replacingOccurrences(of: "\"remainingPercent\": 96.6", with: "\"remainingPercent\": null")
            .replacingOccurrences(of: "\"resetsAt\": \"2026-10-01T00:00:00Z\"", with: "\"resetsAt\": null")
        let result = try CopilotUsageService.decodeOutput(Data(data.utf8), exitCode: 0)
        #expect(result.remainingPercent == nil)
        #expect(result.resetsAt == nil)
    }

    @Test func percentIsNotRecomputedOrClamped() throws {
        for percent in [-1.25, 0, 100, 102.75] {
            let source = fixture.replacingOccurrences(of: "\"remainingPercent\": 96.6", with: "\"remainingPercent\": \(percent)")
            let result = try CopilotUsageService.decodeOutput(Data(source.utf8), exitCode: 0)
            #expect(result.remainingPercent == percent)
        }
    }

    @Test func badTimestampIsSanitized() {
        let data = fixture.replacingOccurrences(of: "2026-09-16T08:30:15.123Z", with: "DO_NOT_LEAK_FIXTURE_SECRET")
        #expect(throws: CopilotUsageError.invalidResponse) {
            try CopilotUsageService.decodeOutput(Data(data.utf8), exitCode: 0)
        }
        #expect(!CopilotUsageError.invalidResponse.localizedDescription.contains("DO_NOT_LEAK"))
    }

    @Test func remoteFailureDoesNotExposeErrorMessageOrUnknownCode() {
        for code in ["authentication_failed", "DO_NOT_LEAK_FIXTURE_SECRET"] {
            let data = Data("""
            {"error":{"code":"\(code)","message":"DO_NOT_LEAK_FIXTURE_SECRET"}}
            """.utf8)
            let expected: CopilotUsageError = code == "authentication_failed" ? .authenticationFailed : .upstreamUnavailable
            #expect(throws: expected) { try CopilotUsageService.decodeOutput(data, exitCode: 1) }
            #expect(!expected.localizedDescription.contains("DO_NOT_LEAK"))
        }
    }

    @Test func sshFailureDoesNotForwardOutput() {
        #expect(throws: CopilotUsageError.connectionFailed) {
            try CopilotUsageService.decodeOutput(Data("DO_NOT_LEAK_FIXTURE_SECRET".utf8), exitCode: 255)
        }
        #expect(!CopilotUsageError.connectionFailed.localizedDescription.contains("DO_NOT_LEAK"))
    }

    @Test func healthIsOptionalAndRejectsNonNumericCount() {
        #expect(CopilotUsageService.modelCount(from: Data(#"{"models":{"count":17}}"#.utf8)) == 17)
        #expect(CopilotUsageService.modelCount(from: Data(#"{"modelsAvailable":0}"#.utf8)) == 0)
        #expect(CopilotUsageService.modelCount(from: Data(#"{"models":{"count":true}}"#.utf8)) == nil)
        #expect(CopilotUsageService.modelCount(from: Data(#"{"modelCount":-1}"#.utf8)) == nil)
        #expect(CopilotUsageService.modelCount(from: Data("unavailable".utf8)) == nil)
    }

    @Test func collectorResourceIsPackaged() throws {
        let source = try #require(CopilotUsageService.collectorURL)
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("def normalize("))
        #expect(text.contains("/copilot_internal/user"))
    }

    @Test func invalidConfigurationDoesNotLaunchSSH() async {
        for service in [CopilotUsageService(sshHost: "-oProxyCommand=bad"), CopilotUsageService(timeout: 0)] {
            await #expect(throws: CopilotUsageError.invalidConfiguration) {
                try await service.fetch()
            }
        }
    }

    /// Opt-in only: two read-only GitHub calls through one SSH invocation.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_ACCOUNT_MENU_LIVE_COPILOT"] == "1"))
    func liveFetchOnlyWhenExplicitlyEnabled() async throws {
        let value = try await CopilotUsageService().fetch()
        #expect(!value.login.isEmpty)
        #expect(!value.plan.isEmpty)
        #expect(abs(value.observedAt.timeIntervalSinceNow) < 120)
        let output = try JSONEncoder().encode(value)
        print("COPILOT_LIVE_SNAPSHOT " + String(decoding: output, as: UTF8.self))
    }
}
