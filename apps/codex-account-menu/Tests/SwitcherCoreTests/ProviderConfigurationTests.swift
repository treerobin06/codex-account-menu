import Foundation
import Testing
@testable import SwitcherCore

struct ProviderConfigurationTests {
    @Test func editsOnlyTheProviderValueAndPreservesSkillAndMCPBytes() async throws {
        let original = """
        # 我的个人配置
        model_provider  = 'openai'  # keep this spacing
        model = "example-model"
        [skills]
        enabled = ["alpha", "beta"]
        [mcp_servers.example]
        command = "/exact/path"
        args = ["#literal", "[not-a-table]"]
        [model_providers.copilot]
        name = "Copilot"
        base_url = "http://127.0.0.1:4141"
        requires_openai_auth = true
        experimental_bearer_token = "local"
        """
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let snapshot = try await fixture.provider.snapshot()
        _ = try await fixture.provider.setProvider("copilot", expecting: snapshot)
        let expected = original.replacingOccurrences(of: "'openai'", with: "'copilot'")
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
        #expect(try await fixture.provider.readProvider() == "copilot")
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    }

    @Test func absentProviderDefaultsToOpenAIAndIsInsertedAtRoot() async throws {
        let original = "# intact\n[skills]\nenabled = true\n" + readyCopilot
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        #expect(try await fixture.provider.readProvider() == "openai")
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "model_provider = \"copilot\"\n" + original)
    }

    @Test func missingConfigIsCreatedWithoutChangingOtherFiles() async throws {
        let fixture = try ProviderFixture(nil)
        defer { fixture.clean() }
        #expect(try await fixture.provider.readProvider() == "openai")
        let snapshot = try await fixture.provider.snapshot()
        _ = try await fixture.provider.setProvider("openai", expecting: snapshot)
        #expect(try Data(contentsOf: fixture.file) == Data("model_provider = \"openai\"\n".utf8))
    }

    @Test func quotedRootKeyIsRecognizedButNestedSettingIsNotTheRoot() async throws {
        let fixture = try ProviderFixture("\"model_provider\" = \"copilot\"\n[profiles.work]\nmodel_provider = \"another\"\n")
        defer { fixture.clean() }
        #expect(try await fixture.provider.readProvider() == "copilot")
        let initial = try await fixture.provider.snapshot()
        _ = try await fixture.provider.setProvider("openai", expecting: initial)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("model_provider = \"another\""))
    }

    @Test func tableLookingTextInsideNestedMultilineStringStaysUntouched() async throws {
        let content = "model_provider = \"openai\"\n[mcp_servers.demo]\nmessage = \"\"\"\n[model_provider.evil]\n#inside\n\"\"\"\n" + readyCopilot
        let fixture = try ProviderFixture(content)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        _ = try await fixture.provider.setProvider("copilot", expecting: initial)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == content.replacingOccurrences(of: "\"openai\"", with: "\"copilot\""))
    }

    @Test(arguments: [
        "model_provider = \"openai\"\nmodel_provider = \"copilot\"\n",
        "model_provider = \"openai\"\n\"model_provider\" = 'copilot'\n",
        "model_provider.type = 'copilot'\n",
        "model_provider = true\n",
        "model_provider = \"\"\n",
        "model_provider = \"co\\u0070ilot\"\n",
        "model_provider = \"openai\"\n[model_provider.other]\n",
        "profile = \"work\"\nmodel_provider = \"openai\"\n[profiles.work]\nmodel_provider = \"copilot\"\n",
        "model_provider = \"unterminated\n",
        "model_provider = \"openai\"\n[unterminated\n"
    ])
    func ambiguousTOMLIsRejectedWithoutEdits(_ content: String) async throws {
        let fixture = try ProviderFixture(content)
        defer { fixture.clean() }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.readProvider() }
        #expect(try Data(contentsOf: fixture.file) == Data(content.utf8))
    }

    @Test func externalRewriteAndSameBytesNewInodeBothRejectCAS() async throws {
        let original = "model_provider = \"openai\"\n" + readyCopilot
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        try Data(original.replacingOccurrences(of: "\"openai\"", with: "\"other\"").utf8).write(to: fixture.file, options: .atomic)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.setProvider("copilot", expecting: initial) }
        #expect(try await fixture.provider.readProvider() == "other")
        let next = try await fixture.provider.snapshot()
        try next.file.data!.write(to: fixture.file, options: .atomic)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.setProvider("copilot", expecting: next) }
    }

    @Test func symlinkConfigurationIsRejected() async throws {
        let fixture = try ProviderFixture(nil)
        defer { fixture.clean() }
        let other = fixture.root.appendingPathComponent("other.toml")
        try Data("model_provider = \"openai\"\n".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: other)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.readProvider() }
        #expect(try Data(contentsOf: other) == Data("model_provider = \"openai\"\n".utf8))
    }

    @Test func copilotPreflightIsReadOnlyAndAddsBothFieldsWithTheRootChange() async throws {
        let original = """
        # 私有配置，保持字节
        model_provider = 'openai' # current
        model = "keep-model"
        model_reasoning_effort = "high"
        [model_providers.copilot] # local proxy
        name = "Copilot"
        base_url = 'http://127.0.0.1:4141/v1'
        wire_api = "responses"
        supports_websockets = true
        request_max_retries = 4
        stream_max_retries = 5
        [model_providers.copilot.auth]
        command = "/usr/bin/printf"
        args = ["local"]
        [skills]
        enabled = ["alpha"]
        [mcp_servers.example]
        command = "/unchanged"
        [plugins.example]
        enabled = true
        """
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let before = try SourceFileSnapshot.read(fixture.file)
        try await fixture.provider.validateCopilotPreservingIdentity()
        #expect(try SourceFileSnapshot.read(fixture.file).identity == before.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let snapshot = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewProvider("copilot", expecting: snapshot)
        let expected = original.replacingOccurrences(of: "'openai'", with: "'copilot'")
            .replacingOccurrences(of: "[model_providers.copilot] # local proxy\n",
                with: "[model_providers.copilot] # local proxy\nrequires_openai_auth = true\nexperimental_bearer_token = \"local\"\n")
            .replacingOccurrences(of: "[model_providers.copilot.auth]\ncommand = \"/usr/bin/printf\"\nargs = [\"local\"]\n", with: "")
        #expect(preview == Data(expected.utf8))
        #expect(try SourceFileSnapshot.read(fixture.file).identity == before.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let installed = try await fixture.provider.setProvider("copilot", expecting: snapshot)
        #expect(installed.file.data == preview)
        #expect(installed.file.data == Data(expected.utf8))
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
        #expect(try SourceFileSnapshot.read(fixture.file).identity?.mode == 0o640)
        // Exact original bytes are the transaction's rollback point.
        _ = try installed.file.replace(with: before.data, privateFile: false)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test func copilotCompletionIsIdempotentAndPreservesQuotedKeysCRLFAndComments() async throws {
        let original = "\"model_provider\" = 'openai' # stay\r\n"
            + "[\"model_providers\" . 'copilot'] # quoted table\r\n"
            + "  'base_url' = \"http://127.0.0.1:4141\" # same endpoint\r\n"
            + "  \"requires_openai_auth\"  = false  # enable identity\r\n"
            + "  'experimental_bearer_token' = 'local' # keep quoting\r\n"
            + "[model_providers.copilot.auth]\r\n'command' = '/usr/bin/printf'\r\n'args' = [ 'local', ]\r\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        let expected = original.replacingOccurrences(of: "'openai'", with: "'copilot'").replacingOccurrences(of: "= false", with: "= true")
            .replacingOccurrences(of: "[model_providers.copilot.auth]\r\n'command' = '/usr/bin/printf'\r\n'args' = [ 'local', ]\r\n", with: "")
        let first = try SourceFileSnapshot.read(fixture.file)
        #expect(first.data == Data(expected.utf8))
        try await fixture.provider.validateCopilotPreservingIdentity()
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        let second = try SourceFileSnapshot.read(fixture.file)
        #expect(second.identity == first.identity)
        #expect(second.data == first.data)
    }

    @Test func legacyPlaceholderRemovalPreservesAllCommentsAndUnrelatedTables() async throws {
        let original = "model_provider='openai'\r\n"
            + "[model_providers.copilot]\r\nbase_url='http://127.0.0.1:4141/v1'\r\nwire_api='responses'\r\n"
            + "# before legacy\r\n"
            + " [\"model_providers\".'copilot'.\"auth\"]  # legacy header note\r\n"
            + "# between header and command\r\n"
            + "\tcommand = '/usr/bin/printf'  # command note\r\n"
            + "args = ['local'] # args note\r\n"
            + "# after legacy\r\n"
            + "[model_providers.other]\r\ncommand='do not remove'\r\nargs=['unchanged']\r\n"
            + "[mcp_servers.demo]\r\ncommand='/keep/mcp'\r\n"
        let expected = "model_provider='copilot'\r\n"
            + "[model_providers.copilot]\r\nrequires_openai_auth = true\r\nexperimental_bearer_token = \"local\"\r\n"
            + "base_url='http://127.0.0.1:4141/v1'\r\nwire_api='responses'\r\n"
            + "# before legacy\r\n   # legacy header note\r\n"
            + "# between header and command\r\n\t  # command note\r\n # args note\r\n"
            + "# after legacy\r\n"
            + "[model_providers.other]\r\ncommand='do not remove'\r\nargs=['unchanged']\r\n"
            + "[mcp_servers.demo]\r\ncommand='/keep/mcp'\r\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let originalSnapshot = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewProvider("copilot", expecting: originalSnapshot)
        #expect(preview == Data(expected.utf8))
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let installed = try await fixture.provider.setProvider("copilot", expecting: originalSnapshot)
        #expect(installed.file.data == preview)
        _ = try await fixture.provider.setProvider("copilot", expecting: installed)
        #expect(try SourceFileSnapshot.read(fixture.file).identity == installed.file.identity)
        _ = try installed.file.replace(with: originalSnapshot.file.data, privateFile: false)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test func legacyPlaceholderAtEOFWithoutNewlineIsRemovedExactly() async throws {
        let original = "model_provider='copilot'\n" + readyCopilot
            + "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['local']"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewProvider("copilot", expecting: initial)
        #expect(preview == Data(("model_provider='copilot'\n" + readyCopilot).utf8))
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let installed = try await fixture.provider.setProvider("copilot", expecting: initial)
        _ = try installed.file.replace(with: initial.file.data, privateFile: false)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test func missingCopilotAuthFieldsUseCRLFAndAreNeverDuplicated() async throws {
        let original = "model_provider = \"copilot\"\r\n[model_providers.copilot]\r\nbase_url = 'http://127.0.0.1:4141/v1'"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        let expected = original.replacingOccurrences(of: "[model_providers.copilot]\r\n",
            with: "[model_providers.copilot]\r\nrequires_openai_auth = true\r\nexperimental_bearer_token = \"local\"\r\n")
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
    }

    @Test func unrelatedMultilineRootAndNestedValuesRemainByteIdentical() async throws {
        let original = "notify = [\n 'line one', # array comment\n 'line two'\n]\n"
            + "instructions = \"\"\"\n[model_providers.copilot]\nbase_url='wrong'\n\"\"\"\n"
            + "\"literal.dot\" = 1\nliteral.dot = 2\n"
            + "model_provider='openai'\n"
            + readyCopilot
            + "[mcp_servers.test]\nmessage = '''\n[model_providers.copilot.auth]\ncommand='evil'\n'''\n"
            + "[model_providers.other]\nhttp_headers = { Authorization = 'untouched' }\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        try await fixture.provider.validateCopilotPreservingIdentity()
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        #expect(try Data(contentsOf: fixture.file) == Data(original.replacingOccurrences(of: "model_provider='openai'", with: "model_provider='copilot'").utf8))
    }

    @Test func switchingToOpenAIOnlyChangesRootEvenWhenCopilotIsUnsupported() async throws {
        let original = "model_provider='copilot'\n[model_providers.copilot]\nbase_url='https://untrusted.example/v1'\nenv_key='KEEP_ME'\nrequires_openai_auth=false\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        _ = try await fixture.provider.setProvider("openai", expecting: fixture.provider.snapshot())
        #expect(try Data(contentsOf: fixture.file) == Data(original.replacingOccurrences(of: "model_provider='copilot'", with: "model_provider='openai'").utf8))
    }

    @Test(arguments: ["\"", "'"], [4, 5])
    func multilineBasicAndLiteralClosingQuotesPreserveFollowingStatements(_ quote: String, _ closingCount: Int) async throws {
        let opening = String(repeating: quote, count: 3)
        let closing = String(repeating: quote, count: closingCount)
        let original = "root_message = \(opening)\n[model_providers.copilot]\nnot a table\n\(closing) # closing comment\n"
            + "notes = [\(opening)array value\(closing), 'tail']\n"
            + "model_provider='openai'\n"
            + readyCopilot
            + "[mcp_servers.example]\nmessage = \(opening)\n[model_providers.copilot.auth]\nnot a command\n\(closing) # another comment\n"
            + "command='/unchanged/after/multiline'\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        #expect(try await fixture.provider.readProvider() == "openai")
        try await fixture.provider.validateCopilotPreservingIdentity()
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        let expected = original.replacingOccurrences(of: "model_provider='openai'", with: "model_provider='copilot'")
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
        #expect(try await fixture.provider.readProvider() == "copilot")
        _ = try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot())
        #expect(try Data(contentsOf: fixture.file) == Data(expected.utf8))
    }

    @Test(arguments: ["\"", "'"])
    func sixClosingQuotesAreRejectedWithoutEditing(_ quote: String) async throws {
        let original = "message = " + String(repeating: quote, count: 3) + "text"
            + String(repeating: quote, count: 6) + "\nmodel_provider='openai'\n" + readyCopilot
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.validateCopilotPreservingIdentity() }
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test(arguments: [
        "", "# no provider\n", "[model_providers.copilot]\nname='missing endpoint'\n",
        "[model_providers.copilot]\nbase_url='https://127.0.0.1:4141/v1'\n",
        "[model_providers.copilot]\nbase_url='http://localhost:4141/v1'\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4142/v1'\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1/'\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1?key=x'\n",
        "[model_providers.copilot]\nbase_url='http://user@127.0.0.1:4141/v1'\n",
        "model_providers = { copilot = { base_url = 'http://127.0.0.1:4141/v1' } }\n",
        "[model_providers]\ncopilot = { base_url = 'http://127.0.0.1:4141/v1' }\n",
        "model_providers.copilot.base_url = 'http://127.0.0.1:4141/v1'\n",
        "[model_providers]\ncopilot.base_url = 'http://127.0.0.1:4141/v1'\n",
        "[[model_providers.copilot]]\nbase_url='http://127.0.0.1:4141/v1'\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\n[model_providers.copilot]\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\n'base_url'='http://127.0.0.1:4141/v1'\n",
        "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\nauth.command='/usr/bin/printf'\n"
    ])
    func missingUnknownOrAmbiguousCopilotFailsBeforeAnyWrite(_ content: String) async throws {
        let fixture = try ProviderFixture(content)
        defer { fixture.clean() }
        let before = try SourceFileSnapshot.read(fixture.file)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.validateCopilotPreservingIdentity() }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot()) }
        #expect(try SourceFileSnapshot.read(fixture.file).identity == before.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(content.utf8))
    }

    @Test(arguments: [
        "env_key='OTHER_TOKEN'\n", "env_key_instructions='use another key'\n",
        "http_headers={Authorization='another'}\n", "env_http_headers={Authorization='ENV'}\n",
        "requires_openai_auth='true'\n", "requires_openai_auth=true\n'requires_openai_auth'=true\n",
        "experimental_bearer_token='another-secret'\n", "experimental_bearer_token='local'\nexperimental_bearer_token='local'\n",
        "auth={command='/usr/bin/printf',args=['local']}\n",
        "[model_providers.copilot.auth]\ncommand='/bin/echo'\nargs=['local']\n",
        "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['different']\n",
        "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['local','extra']\n",
        "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['local']\nenv_key='OTHER'\n",
        "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\n",
        "[model_providers.copilot.http_headers]\nAuthorization='other'\n"
    ])
    func conflictingCopilotAuthenticationIsRejectedWithoutEchoingValues(_ suffix: String) async throws {
        let original = "model_provider='openai'\n[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\n" + suffix
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let snapshot = try await fixture.provider.snapshot()
        do {
            try await fixture.provider.validateCopilotPreservingIdentity()
            Issue.record("Expected authentication conflict")
        } catch {
            #expect(error is SourceFileError)
            #expect(!error.localizedDescription.contains("another-secret"))
        }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.previewProvider("copilot", expecting: snapshot) }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.setProvider("copilot", expecting: fixture.provider.snapshot()) }
        #expect(try SourceFileSnapshot.read(fixture.file).identity == snapshot.file.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test(arguments: [nil, "'file'", "\"file\"", "'auto'", "'keyring'", "'ephemeral'", "true"] as [String?])
    func onlyFileCredentialStorageOrItsDefaultIsAllowed(_ value: String?) async throws {
        let content = value.map { "cli_auth_credentials_store = \($0)\n" } ?? ""
        let fixture = try ProviderFixture(content + readyCopilot)
        defer { fixture.clean() }
        if value == nil || value == "'file'" || value == "\"file\"" {
            try await fixture.provider.validateCopilotPreservingIdentity()
        } else {
            await #expect(throws: SourceFileError.self) { try await fixture.provider.validateCopilotPreservingIdentity() }
        }
        #expect(try Data(contentsOf: fixture.file) == Data((content + readyCopilot).utf8))
    }

    @Test func managedAPIWithIdentityUsesPhysicalOpenAIAndOnlyTheOwnedRelayURL() async throws {
        let original = "# personal note\r\nmodel_provider = 'openai' # selected\r\nmodel='keep-model'\r\nmodel_reasoning_effort='high'\r\n"
            + "[model_providers.copilot]\r\nbase_url='http://127.0.0.1:4141/v1'\r\nwire_api='responses'\r\nsupports_websockets=true\r\n"
            + "requires_openai_auth=true\r\nexperimental_bearer_token='local'\r\n"
            + "[mcp_servers.demo]\r\ncommand='/keep/mcp'\r\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewRoute("copilot", hasOfficialIdentity: true, expecting: initial)
        let expected = ProviderRouteState.managedMarker + "\r\nopenai_base_url = \"" + ProviderRouteState.relayBaseURL + "\"\r\n"
            + original.replacingOccurrences(of: "base_url='http://127.0.0.1:4141/v1'", with: "base_url='http://127.0.0.1:4142/v1'")
                .replacingOccurrences(of: "requires_openai_auth=true", with: "requires_openai_auth=false")
        #expect(preview == Data(expected.utf8))
        #expect(try SourceFileSnapshot.read(fixture.file).identity == initial.file.identity)
        let installed = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: true, expecting: initial)
        #expect(installed.provider == "copilot")
        #expect(installed.physicalProvider == "openai")
        #expect(installed.file.data == preview)
        let state = try await fixture.provider.readRoute()
        #expect(state.logicalProvider == "copilot")
        #expect(state.physicalProvider == "openai")
        #expect(state.isManaged && state.apiEnabled)
        #expect(try await fixture.provider.readProvider() == "copilot")
        _ = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: true, expecting: installed)
        #expect(try SourceFileSnapshot.read(fixture.file).identity == installed.file.identity)
    }

    @Test func managedRouteTransitionsRetainLegacyRelayAndRestoreTheOriginalBytes() async throws {
        let original = "model_provider='copilot'\n" + readyCopilot
            + "[model_providers.copilot.auth]\ncommand='/usr/bin/printf'\nargs=['local']\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let first = try await fixture.provider.snapshot()
        _ = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: true, expecting: first)
        let api = try await fixture.provider.snapshot()
        let native = try await fixture.provider.setRoute("openai", hasOfficialIdentity: true, expecting: api)
        #expect(native.provider == "openai" && native.physicalProvider == "openai")
        let nativeBytes = try #require(native.file.data)
        let nativeText = try #require(String(data: nativeBytes, encoding: .utf8))
        #expect(nativeText.contains(ProviderRouteState.managedMarker))
        #expect(!nativeText.contains("openai_base_url"))
        #expect(nativeText.contains("base_url='http://127.0.0.1:4142/v1'"))
        #expect(nativeText.contains("requires_openai_auth=false"))
        #expect(!nativeText.contains("[model_providers.copilot.auth]"))
        #expect(try await fixture.provider.readRoute().apiEnabled == false)

        let pureAPI = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: false, expecting: native)
        #expect(pureAPI.provider == "copilot" && pureAPI.physicalProvider == "copilot")
        #expect(try await fixture.provider.readRoute().apiEnabled)
        let pureAPIBytes = try #require(pureAPI.file.data)
        #expect(String(decoding: pureAPIBytes, as: UTF8.self)
            .contains("openai_base_url = \"\(ProviderRouteState.relayBaseURL)\""))

        let officialAPI = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: true, expecting: pureAPI)
        #expect(officialAPI.provider == "copilot" && officialAPI.physicalProvider == "openai")
        #expect(officialAPI.file.data == api.file.data)
        _ = try officialAPI.file.replace(with: first.file.data, privateFile: false)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let restored = try await fixture.provider.readRoute()
        #expect(restored.logicalProvider == "copilot" && restored.physicalProvider == "copilot")
        #expect(!restored.isManaged && !restored.apiEnabled)
    }

    @Test func managedPureAPIGuardsTheLegacyOpenAIEntryWithoutChangingRetainedAuth() async throws {
        let original = "# retain root bytes\r\nmodel_provider='openai' # selected\r\n"
            + readyCopilot.replacingOccurrences(of: "\n", with: "\r\n")
            + "[mcp_servers.demo]\r\ncommand='/keep/mcp'\r\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let retainedAuth = fixture.root.appendingPathComponent("auth.json")
        let authBytes = Data("{\"synthetic_retained_auth\":true}".utf8)
        try authBytes.write(to: retainedAuth)
        let before = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewRoute("copilot", hasOfficialIdentity: false, expecting: before)
        let expected = ProviderRouteState.managedMarker + "\r\n"
            + "openai_base_url = \"\(ProviderRouteState.relayBaseURL)\"\r\n"
            + original.replacingOccurrences(of: "model_provider='openai'", with: "model_provider='copilot'")
                .replacingOccurrences(of: "base_url='http://127.0.0.1:4141/v1'", with: "base_url='http://127.0.0.1:4142/v1'")
                .replacingOccurrences(of: "requires_openai_auth=true", with: "requires_openai_auth=false")
        #expect(preview == Data(expected.utf8))
        #expect(try SourceFileSnapshot.read(fixture.file).identity == before.file.identity)
        let installed = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: false, expecting: before)
        #expect(installed.file.data == preview)
        #expect(try await fixture.provider.readRoute() == ProviderRouteState(logicalProvider: "copilot",
            physicalProvider: "copilot", isManaged: true, apiEnabled: true))
        #expect(try Data(contentsOf: retainedAuth) == authBytes)
        _ = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: false, expecting: installed)
        #expect(try SourceFileSnapshot.read(fixture.file).identity == installed.file.identity)
        let native = try await fixture.provider.setRoute("openai", hasOfficialIdentity: true, expecting: installed)
        #expect(!String(decoding: try #require(native.file.data), as: UTF8.self).contains("openai_base_url"))
        #expect(try Data(contentsOf: retainedAuth) == authBytes)
    }

    @Test func managedPhysicalCopilotWithoutTheLegacyOpenAIGuardIsRejected() async throws {
        let original = ProviderRouteState.managedMarker + "\nmodel_provider='copilot'\n"
            + readyCopilot.replacingOccurrences(of: "4141", with: "4142")
                .replacingOccurrences(of: "requires_openai_auth=true", with: "requires_openai_auth=false")
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let before = try SourceFileSnapshot.read(fixture.file)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.readRoute() }
        await #expect(throws: SourceFileError.self) { try await fixture.provider.snapshot() }
        #expect(try SourceFileSnapshot.read(fixture.file).identity == before.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test(arguments: [nil, "# only native\nmodel='keep'\n[mcp_servers.demo]\ncommand='untouched'\n"] as [String?])
    func nativeRouteDoesNotRequireOrInventACopilotProvider(_ original: String?) async throws {
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let before = try await fixture.provider.snapshot()
        let installed = try await fixture.provider.setRoute("openai", hasOfficialIdentity: true, expecting: before)
        let installedBytes = try #require(installed.file.data)
        let text = try #require(String(data: installedBytes, encoding: .utf8))
        #expect(installed.provider == "openai" && installed.physicalProvider == "openai")
        #expect(text.contains(ProviderRouteState.managedMarker))
        #expect(!text.contains("model_providers.copilot"))
        #expect(!text.contains("openai_base_url"))
        if let original { #expect(text.hasSuffix(original)) }
        #expect(try await fixture.provider.readRoute().isManaged)
        #expect(try await fixture.provider.readRoute().apiEnabled == false)
        await #expect(throws: SourceFileError.self) {
            try await fixture.provider.previewRoute("copilot", hasOfficialIdentity: true, expecting: installed)
        }
    }

    @Test(arguments: ["https://user-config.example/v1", "http://127.0.0.1:4142/v1", "http://127.0.0.1:4141/v1"])
    func unmarkedUserOpenAIBaseURLCannotBeOverwrittenOrRemoved(_ endpoint: String) async throws {
        let original = "model_provider='openai'\nopenai_base_url='\(endpoint)'\n" + readyCopilot
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        #expect(try await fixture.provider.readRoute().isManaged == false)
        for hasOfficialIdentity in [false, true] {
            for logical in ["openai", "copilot"] {
                await #expect(throws: SourceFileError.self) {
                    try await fixture.provider.previewRoute(logical, hasOfficialIdentity: hasOfficialIdentity, expecting: initial)
                }
                await #expect(throws: SourceFileError.self) {
                    try await fixture.provider.setRoute(logical, hasOfficialIdentity: hasOfficialIdentity, expecting: initial)
                }
            }
        }
        #expect(try SourceFileSnapshot.read(fixture.file).identity == initial.file.identity)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test(arguments: [false, true])
    func routeMarkerDoesNotAuthorizeAChangedURLOrCompatibilityProvider(hasOfficialIdentity: Bool) async throws {
        let fixture = try ProviderFixture("model_provider='openai'\n" + readyCopilot)
        defer { fixture.clean() }
        let installed = try await fixture.provider.setRoute("copilot", hasOfficialIdentity: hasOfficialIdentity, expecting: fixture.provider.snapshot())
        let managedBytes = try #require(installed.file.data)
        let managed = try #require(String(data: managedBytes, encoding: .utf8))
        for modified in [
            managed.replacingOccurrences(of: "openai_base_url = \"http://127.0.0.1:4142/v1\"", with: "openai_base_url = \"https://user-edit.example/v1\""),
            managed.replacingOccurrences(of: "base_url='http://127.0.0.1:4142/v1'", with: "base_url='http://127.0.0.1:4141/v1'"),
            managed.replacingOccurrences(of: "requires_openai_auth=false", with: "requires_openai_auth=true"),
        ] {
            try Data(modified.utf8).write(to: fixture.file, options: .atomic)
            await #expect(throws: SourceFileError.self) { try await fixture.provider.readRoute() }
            #expect(try Data(contentsOf: fixture.file) == Data(modified.utf8))
        }
    }

    @Test func onlyARealRootCommentOwnsTheRelayURL() async throws {
        let quotedMarker = "note = \"\"\"\n\(ProviderRouteState.managedMarker)\n\"\"\"\n"
        let original = quotedMarker + "model_provider='openai'\nopenai_base_url='http://127.0.0.1:4142/v1'\n" + readyCopilot
            + "[mcp_servers.demo]\n\(ProviderRouteState.managedMarker)\ncommand='keep'\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        #expect(try await fixture.provider.readRoute().isManaged == false)
        await #expect(throws: SourceFileError.self) {
            try await fixture.provider.previewRoute("openai", hasOfficialIdentity: true, expecting: fixture.provider.snapshot())
        }
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test func nativeRemovesOnlyTheOwnedURLStatementAndKeepsItsInlineComment() async throws {
        let original = ProviderRouteState.managedMarker + "\nmodel_provider='openai'\n"
            + "openai_base_url='http://127.0.0.1:4142/v1'  # keep URL note\n"
            + "[mcp_servers.demo]\ncommand='untouched'\n"
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let initial = try await fixture.provider.snapshot()
        #expect(initial.provider == "copilot" && initial.physicalProvider == "openai")
        let preview = try await fixture.provider.previewRoute("openai", hasOfficialIdentity: true, expecting: initial)
        let expected = original.replacingOccurrences(of: "openai_base_url='http://127.0.0.1:4142/v1'", with: "")
        #expect(preview == Data(expected.utf8))
        let native = try await fixture.provider.setRoute("openai", hasOfficialIdentity: true, expecting: initial)
        #expect(native.provider == "openai" && native.physicalProvider == "openai")
        #expect(native.file.data == preview)
        _ = try native.file.replace(with: initial.file.data, privateFile: false)
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
    }

    @Test func managedRoutesRejectAnActiveProfileButPreserveInactiveProfileDefinitions() async throws {
        let inactive = "model_provider='openai'\n" + readyCopilot
            + "[profiles.other]\nmodel_provider='other'\nopenai_base_url='https://unused-profile.example/v1'\n"
        let fixture = try ProviderFixture(inactive)
        defer { fixture.clean() }
        let before = try await fixture.provider.snapshot()
        let preview = try await fixture.provider.previewRoute("copilot", hasOfficialIdentity: true, expecting: before)
        #expect(String(decoding: preview, as: UTF8.self).hasSuffix("[profiles.other]\nmodel_provider='other'\nopenai_base_url='https://unused-profile.example/v1'\n"))
        let active = "profile='other'\n" + inactive
        try Data(active.utf8).write(to: fixture.file, options: .atomic)
        await #expect(throws: SourceFileError.self) { try await fixture.provider.snapshot() }
        #expect(try Data(contentsOf: fixture.file) == Data(active.utf8))
    }

    @Test func managedRoutesRejectTheKnownBaseURLEnvironmentOverrideWithoutEchoingItsValue() async throws {
        let original = "model_provider='openai'\n" + readyCopilot
        let fixture = try ProviderFixture(original)
        defer { fixture.clean() }
        let configured = ProviderConfiguration(codexHome: fixture.root,
            environment: ["OPENAI_BASE_URL": "https://private-environment.example/v1"])
        let before = try await configured.snapshot()
        for logical in ["openai", "copilot"] {
            do {
                _ = try await configured.previewRoute(logical, hasOfficialIdentity: true, expecting: before)
                Issue.record("An environment override must not be treated as a controlled route.")
            } catch {
                #expect(error is SourceFileError)
                #expect(!error.localizedDescription.contains("private-environment.example"))
            }
        }
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        let clean = ProviderConfiguration(codexHome: fixture.root, environment: ["HTTPS_PROXY": "http://127.0.0.1:7897"])
        _ = try await clean.previewRoute("copilot", hasOfficialIdentity: true, expecting: clean.snapshot())
    }
}

private let readyCopilot = "[model_providers.copilot]\nbase_url='http://127.0.0.1:4141/v1'\nrequires_openai_auth=true\nexperimental_bearer_token='local'\n"

private struct ProviderFixture {
    let root: URL
    let file: URL
    let provider: ProviderConfiguration
    init(_ contents: String?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        file = root.appendingPathComponent("config.toml")
        if let contents {
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        }
        provider = ProviderConfiguration(codexHome: root)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
