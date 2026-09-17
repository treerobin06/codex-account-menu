import Foundation
import Testing
@testable import SwitcherCore

struct AccountProxyEnvironmentTests {
    @Test func finderEnvironmentUsesExistingProxyAndBypassesTheModelRelay() {
        let input = ["PATH": "/usr/bin:/bin"]
        let result = AccountRPCConfiguration.environment(input, profileHome: URL(fileURLWithPath: "/tmp/account-proxy-fixture"))
        #expect(result["HTTPS_PROXY"] == "http://127.0.0.1:7897")
        #expect(result["https_proxy"] == result["HTTPS_PROXY"])
        #expect(result["HTTP_PROXY"] == result["HTTPS_PROXY"])
        #expect(result["ALL_PROXY"] == result["HTTPS_PROXY"] && result["all_proxy"] == result["HTTPS_PROXY"])
        #expect(result["NO_PROXY"] == "localhost,127.0.0.1,::1")
        #expect(result["no_proxy"] == result["NO_PROXY"])
        #expect(result["CODEX_HOME"] == "/tmp/account-proxy-fixture")
        #expect(input == ["PATH": "/usr/bin:/bin"])
        #expect(AccountProxyEnvironment.applying(to: result) == result)
    }

    @Test(arguments: AccountProxyEnvironment.proxyKeys, ["", "http://explicit.example.test:8888"])
    func callerProxyPolicyIsPreserved(key: String, value: String) {
        let input = [key: value, "NO_PROXY": "custom.example.test"]
        #expect(AccountProxyEnvironment.applying(to: input) == input)
    }

    @Test func existingExceptionsAndCredentialIsolationSurvive() {
        let result = AccountRPCConfiguration.environment([
            "no_proxy": "example.test,.local,127.0.0.1", "OPENAI_API_KEY": "synthetic-secret",
            "OPENAI_BASE_URL": "https://wrong.example.test/v1", "GITHUB_TOKEN": "synthetic-secret"
        ], profileHome: URL(fileURLWithPath: "/tmp/account-proxy-fixture"))
        #expect(result["no_proxy"] == "example.test,.local,127.0.0.1,localhost,::1")
        #expect(result["NO_PROXY"] == result["no_proxy"])
        #expect(result["OPENAI_API_KEY"] == nil && result["OPENAI_BASE_URL"] == nil && result["GITHUB_TOKEN"] == nil)
    }
}
