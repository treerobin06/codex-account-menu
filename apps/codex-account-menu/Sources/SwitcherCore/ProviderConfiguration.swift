import Foundation
import Darwin

public enum SourceFileError: LocalizedError, Sendable {
    case changed(String)
    case unsafe(String)
    case invalidConfiguration(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case .changed(let name): "Concurrent modification detected in \(name); the external change was preserved."
        case .unsafe(let name): "\(name) must be a regular file, not a link or directory."
        case .invalidConfiguration(let detail): "Unsupported or ambiguous config.toml: \(detail)"
        case .busy: "Another source switch is already running."
        }
    }
}

public struct ProviderRouteState: Equatable, Sendable {
    public static let managedMarker = "# codex-account-menu managed-route v1"
    public static let relayBaseURL = "http://127.0.0.1:4142/v1"
    public let logicalProvider: String
    public let physicalProvider: String
    public let isManaged: Bool
    /// Whether this managed configuration requires the API relay to be enabled.
    public let apiEnabled: Bool
}

/// Edits the root provider and the local Copilot authentication fields, removing
/// only its recognized legacy placeholder auth command and retaining other bytes.
public actor ProviderConfiguration {
    public let codexHome: URL
    private let environment: [String: String]

    public init(codexHome: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.codexHome = codexHome
        self.environment = environment
    }

    public func readProvider() throws -> String {
        try snapshot().provider
    }

    public func readRoute() throws -> ProviderRouteState {
        let file = try SourceFileSnapshot.read(codexHome.appendingPathComponent("config.toml"))
        let state = try ProviderDocument(file.data ?? Data()).routeState()
        try file.requireUnchanged()
        return state
    }

    /// Read-only preflight; additions are planned here but written only by setProvider.
    public func validateCopilotPreservingIdentity() throws {
        let file = try SourceFileSnapshot.read(codexHome.appendingPathComponent("config.toml"))
        let document = try ProviderDocument(file.data ?? Data())
        try document.validateCopilotPreservingIdentity()
        try file.requireUnchanged()
    }

    func snapshot() throws -> ProviderSnapshot {
        let file = try SourceFileSnapshot.read(codexHome.appendingPathComponent("config.toml"))
        let parsed = try ProviderDocument(file.data ?? Data())
        let state = try parsed.routeState()
        return ProviderSnapshot(file: file, provider: state.logicalProvider, physicalProvider: state.physicalProvider)
    }

    func previewProvider(_ provider: String, expecting snapshot: ProviderSnapshot) throws -> Data {
        guard provider == "openai" || provider == "copilot" else {
            throw SourceFileError.invalidConfiguration("the requested provider is not supported")
        }
        let document = try ProviderDocument(snapshot.file.data ?? Data())
        let bytes = try document.settingProvider(provider)
        try snapshot.file.requireUnchanged()
        return bytes
    }

    func setProvider(_ provider: String, expecting snapshot: ProviderSnapshot) throws -> ProviderSnapshot {
        let bytes = try previewProvider(provider, expecting: snapshot)
        let state = try ProviderDocument(bytes).routeState()
        let file = try snapshot.file.replace(with: bytes, privateFile: false)
        return ProviderSnapshot(file: file, provider: state.logicalProvider, physicalProvider: state.physicalProvider)
    }

    func previewRoute(_ logicalProvider: String, hasOfficialIdentity: Bool, expecting snapshot: ProviderSnapshot) throws -> Data {
        if let override = environment["OPENAI_BASE_URL"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SourceFileError.invalidConfiguration("OPENAI_BASE_URL is set in the process environment; refusing an ambiguous managed route")
        }
        let document = try ProviderDocument(snapshot.file.data ?? Data())
        let bytes = try document.settingRoute(logicalProvider, hasOfficialIdentity: hasOfficialIdentity)
        try snapshot.file.requireUnchanged()
        return bytes
    }

    func setRoute(_ logicalProvider: String, hasOfficialIdentity: Bool, expecting snapshot: ProviderSnapshot) throws -> ProviderSnapshot {
        let bytes = try previewRoute(logicalProvider, hasOfficialIdentity: hasOfficialIdentity, expecting: snapshot)
        let state = try ProviderDocument(bytes).routeState()
        let file = try snapshot.file.replace(with: bytes, privateFile: false)
        return ProviderSnapshot(file: file, provider: state.logicalProvider, physicalProvider: state.physicalProvider)
    }
}

struct ProviderSnapshot: Sendable {
    let file: SourceFileSnapshot
    let provider: String
    let physicalProvider: String

    init(file: SourceFileSnapshot, provider: String, physicalProvider: String? = nil) {
        self.file = file
        self.provider = provider
        self.physicalProvider = physicalProvider ?? provider
    }
}

private struct ProviderDocument {
    let bytes: Data
    let provider: String
    let valueRange: Range<Int>?
    let newline: [UInt8]
    private let rootSettings: [String: Assignment]
    private let routeMarkerEnd: Int?
    private var hasRouteMarker: Bool { routeMarkerEnd != nil }
    private let ambiguousRouteURL: Bool

    init(_ bytes: Data) throws {
        guard String(data: bytes, encoding: .utf8) != nil,
              !bytes.starts(with: [0xEF, 0xBB, 0xBF]), !bytes.contains(0) else {
            throw SourceFileError.invalidConfiguration("expected UTF-8 without a BOM or NUL")
        }
        self.bytes = bytes
        let input = Array(bytes)
        newline = input.contains(13) ? [13, 10] : [10]
        var root = true
        var providerValue: String?
        var foundRange: Range<Int>?
        var rootKeys: Set<[String]> = []
        var settings: [String: Assignment] = [:]
        var markerEnd: Int?
        var ambiguousURL = false
        for range in try Self.statements(input) {
            let statement = Array(input[range])
            let rawText = String(decoding: statement, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if root, rawText == ProviderRouteState.managedMarker {
                guard markerEnd == nil else { throw Self.invalid("duplicate managed route marker") }
                markerEnd = range.upperBound
            }
            let visible = Self.withoutComment(statement)
            let text = String(decoding: visible, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text.hasPrefix("[") {
                let arrayTable = text.hasPrefix("[[")
                let opening = arrayTable ? 2 : 1
                let closing = arrayTable ? "]]" : "]"
                guard text.hasSuffix(closing) else { throw Self.invalid("invalid table header") }
                let keys = try Self.keyPath(String(text.dropFirst(opening).dropLast(opening)))
                guard keys.first != "model_provider" else { throw Self.invalid("model_provider is also declared as a table") }
                if keys.first == "openai_base_url" { ambiguousURL = true }
                root = false
                continue
            }
            guard root else { continue }
            guard let equals = Self.equalsOffset(visible) else { throw Self.invalid("expected a root key = value assignment") }
            let keys = try Self.keyPath(String(decoding: visible[..<equals], as: UTF8.self))
            let key = keys.joined(separator: ".")
            guard rootKeys.insert(keys).inserted else { throw Self.invalid("duplicate root key \(key)") }
            if keys.count == 1 { settings[keys[0]] = try Self.assignment(visible, in: range) }
            if keys.first == "openai_base_url", keys.count != 1 { ambiguousURL = true }
            guard keys.first != "profile" else {
                throw Self.invalid("a selected root profile may override model_provider; remove the selection before switching sources")
            }
            guard keys.first == "model_provider" else { continue }
            guard keys.count == 1, providerValue == nil else { throw Self.invalid("ambiguous model_provider key") }
            guard !text.contains("\n"), !text.contains("\r") else {
                throw Self.invalid("multiline model_provider values are not supported")
            }
            var begin = equals + 1
            while begin < visible.count && (visible[begin] == 32 || visible[begin] == 9) { begin += 1 }
            var end = visible.count
            while end > begin && [9, 10, 13, 32].contains(visible[end - 1]) { end -= 1 }
            guard end - begin >= 3, [34, 39].contains(visible[begin]), visible[end - 1] == visible[begin] else {
                throw Self.invalid("model_provider must be a nonempty quoted string")
            }
            let value = Array(visible[(begin + 1)..<(end - 1)])
            guard value.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw Self.invalid("model_provider must be a simple provider identifier")
            }
            providerValue = String(decoding: value, as: UTF8.self)
            foundRange = (range.lowerBound + begin + 1)..<(range.lowerBound + end - 1)
        }
        provider = providerValue ?? "openai"
        valueRange = foundRange
        rootSettings = settings
        routeMarkerEnd = markerEnd
        ambiguousRouteURL = ambiguousURL
    }

    func routeState() throws -> ProviderRouteState {
        guard hasRouteMarker else {
            return ProviderRouteState(logicalProvider: provider, physicalProvider: provider, isManaged: false, apiEnabled: false)
        }
        try requireOwnedRouteURL()
        guard provider == "openai" || provider == "copilot" else { throw Self.invalid("unsupported physical provider under the managed route marker") }
        let compatibilityChanges = try copilotIdentityEdits(requiresOpenaiAuth: false, relayRoute: true,
            allowMissing: provider == "openai", acceptsRelay: true, enforceFileStore: false)
        guard compatibilityChanges.isEmpty else { throw Self.invalid("managed Copilot compatibility fields were changed outside the route transaction") }
        let hasRelayURL = rootSettings["openai_base_url"] != nil
        guard provider != "copilot" || hasRelayURL else { throw Self.invalid("managed API route requires the owned OpenAI relay URL") }
        let apiEnabled = hasRelayURL
        return ProviderRouteState(logicalProvider: apiEnabled ? "copilot" : "openai", physicalProvider: provider,
            isManaged: true, apiEnabled: apiEnabled)
    }

    func settingRoute(_ logicalProvider: String, hasOfficialIdentity: Bool) throws -> Data {
        guard logicalProvider == "openai" || logicalProvider == "copilot" else { throw Self.invalid("unsupported logical provider") }
        try requireOwnedRouteURL()
        let nativePhysical = logicalProvider == "openai" || hasOfficialIdentity
        let physical = nativePhysical ? "openai" : "copilot"
        // Even pure API mode must guard old threads that still name openai.
        // Only an explicit native selection may restore the official endpoint.
        let needsOpenAIRelayURL = logicalProvider == "copilot"
        var edits = try copilotIdentityEdits(requiresOpenaiAuth: false, relayRoute: true,
            allowMissing: logicalProvider == "openai", acceptsRelay: hasRouteMarker,
            enforceFileStore: logicalProvider == "copilot" && hasOfficialIdentity)
        var prefix: [String] = []
        if !hasRouteMarker { prefix.append(ProviderRouteState.managedMarker) }
        if let valueRange { edits.append(Edit(range: valueRange, replacement: Data(physical.utf8))) }
        if needsOpenAIRelayURL {
            if rootSettings["openai_base_url"] == nil {
                let line = "openai_base_url = \"\(ProviderRouteState.relayBaseURL)\""
                if let routeMarkerEnd {
                    edits.append(Edit(range: routeMarkerEnd..<routeMarkerEnd, replacement: Data(Array(line.utf8) + newline)))
                } else { prefix.append(line) }
            }
        } else if let field = rootSettings["openai_base_url"] {
            edits.append(Self.removingStatementPreservingComment(Array(bytes[field.statementRange]), in: field.statementRange))
        }
        if valueRange == nil { prefix.append("model_provider = \"\(physical)\"") }
        if !prefix.isEmpty {
            let insertion = prefix.flatMap { Array($0.utf8) + newline }
            edits.append(Edit(range: 0..<0, replacement: Data(insertion)))
        }
        return applying(edits)
    }

    private func requireOwnedRouteURL() throws {
        guard !ambiguousRouteURL else { throw Self.invalid("ambiguous openai_base_url declaration") }
        guard let field = rootSettings["openai_base_url"] else { return }
        guard hasRouteMarker, try Self.simpleString(field.value) == ProviderRouteState.relayBaseURL else {
            throw Self.invalid("openai_base_url is user-owned or changed; refusing to overwrite or remove it")
        }
    }

    func validateCopilotPreservingIdentity() throws {
        _ = try copilotIdentityEdits()
    }

    func settingProvider(_ value: String) throws -> Data {
        var edits = value == "copilot" ? try copilotIdentityEdits() : []
        if let valueRange { edits.append(Edit(range: valueRange, replacement: Data(value.utf8))) }
        else {
            edits.append(Edit(range: 0..<0, replacement: Data(Array("model_provider = \"\(value)\"".utf8) + newline)))
        }
        return applying(edits)
    }

    private func applying(_ edits: [Edit]) -> Data {
        var result = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    private struct Edit {
        let range: Range<Int>
        let replacement: Data
    }

    private struct Assignment {
        let keys: [String]
        let value: String
        let valueRange: Range<Int>
        let statementRange: Range<Int>
    }

    /// The supported shape is deliberately narrow: one explicit Copilot table,
    /// optionally its known local printf auth command, which must be removed when
    /// installing explicit bearer/identity fields. Unknown auth sources fail closed.
    private func copilotIdentityEdits(requiresOpenaiAuth: Bool = true, relayRoute: Bool = false,
                                      allowMissing: Bool = false, acceptsRelay: Bool = false,
                                      enforceFileStore: Bool = true) throws -> [Edit] {
        let input = Array(bytes)
        let providerPath = ["model_providers", "copilot"]
        let authPath = providerPath + ["auth"]
        let conflictingKeys: Set<String> = ["env_key", "env_key_instructions", "http_headers", "env_http_headers"]
        var context: [String] = []
        var headerEnd: Int?
        var hasAuthTable = false
        var fields: [String: Assignment] = [:]
        var authFields: [String: Assignment] = [:]
        var legacyAuthRemovals: [Edit] = []
        for range in try Self.statements(input) {
            let visible = Self.withoutComment(Array(input[range]))
            let text = String(decoding: visible, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text.hasPrefix("[") {
                let isArray = text.hasPrefix("[[")
                let width = isArray ? 2 : 1
                guard text.hasSuffix(isArray ? "]]" : "]") else { throw Self.invalid("invalid table header") }
                context = try Self.keyPath(String(text.dropFirst(width).dropLast(width)))
                if context == ["model_providers"], isArray { throw Self.invalid("model_providers cannot be an array table") }
                if context.starts(with: providerPath) {
                    guard !isArray else { throw Self.invalid("Copilot cannot be an array table") }
                    if context == providerPath {
                        guard headerEnd == nil else { throw Self.invalid("duplicate Copilot table") }
                        headerEnd = range.upperBound
                    } else if context == authPath {
                        guard !hasAuthTable else { throw Self.invalid("duplicate Copilot auth table") }
                        hasAuthTable = true
                        legacyAuthRemovals.append(Self.removingStatementPreservingComment(Array(input[range]), in: range))
                    } else { throw Self.invalid("unsupported Copilot subtable") }
                }
                continue
            }
            // No value in an unrelated provider, profile, skill or MCP table is parsed.
            guard context.isEmpty || context == ["model_providers"] || context.starts(with: providerPath) else { continue }
            let assignment = try Self.assignment(visible, in: range)
            let path = context + assignment.keys
            if enforceFileStore, context.isEmpty, assignment.keys.first == "cli_auth_credentials_store" {
                guard assignment.keys.count == 1, try Self.simpleString(assignment.value) == "file" else {
                    throw Self.invalid("identity-preserving Copilot requires the file credential store")
                }
            }
            if context == providerPath {
                guard assignment.keys.count == 1 else { throw Self.invalid("dotted Copilot assignments are unsupported") }
                let key = assignment.keys[0]
                guard fields[key] == nil else { throw Self.invalid("duplicate Copilot key \(key)") }
                guard key != "auth", !conflictingKeys.contains(key) else {
                    throw Self.invalid("conflicting or ambiguous Copilot authentication field \(key)")
                }
                fields[key] = assignment
            } else if context == authPath {
                guard assignment.keys.count == 1, ["command", "args"].contains(assignment.keys[0]) else {
                    throw Self.invalid("unsupported Copilot auth command option")
                }
                let key = assignment.keys[0]
                guard authFields[key] == nil else { throw Self.invalid("duplicate Copilot auth key \(key)") }
                authFields[key] = assignment
                legacyAuthRemovals.append(Self.removingStatementPreservingComment(Array(input[range]), in: range))
            } else if path == ["model_providers"] || path.starts(with: providerPath) {
                throw Self.invalid("Copilot must use an explicit table, not inline or dotted assignments")
            }
        }
        if allowMissing, headerEnd == nil, !hasAuthTable { return [] }
        var endpoints = ["http://127.0.0.1:4141", "http://127.0.0.1:4141/v1"]
        if acceptsRelay { endpoints.append(ProviderRouteState.relayBaseURL) }
        guard let headerEnd, let endpoint = fields["base_url"],
              endpoints.contains(try Self.simpleString(endpoint.value)) else {
            throw Self.invalid("Copilot must already use the expected local 127.0.0.1:4141 endpoint")
        }
        if hasAuthTable {
            guard let command = authFields["command"], let args = authFields["args"],
                  try Self.simpleString(command.value) == "/usr/bin/printf",
                  try Self.singleStringArray(args.value) == "local" else {
                throw Self.invalid("only the existing local printf authentication command is supported")
            }
        }
        var edits = legacyAuthRemovals
        var additions: [String] = []
        if relayRoute, try Self.simpleString(endpoint.value) != ProviderRouteState.relayBaseURL {
            let quote = String(endpoint.value.prefix(1))
            edits.append(Edit(range: endpoint.valueRange, replacement: Data((quote + ProviderRouteState.relayBaseURL + quote).utf8)))
        }
        let requirement = requiresOpenaiAuth ? "true" : "false"
        if let field = fields["requires_openai_auth"] {
            guard field.value == "true" || field.value == "false" else { throw Self.invalid("requires_openai_auth must be a boolean") }
            if field.value != requirement { edits.append(Edit(range: field.valueRange, replacement: Data(requirement.utf8))) }
        } else { additions.append("requires_openai_auth = \(requirement)") }
        if let field = fields["experimental_bearer_token"] {
            guard try Self.simpleString(field.value) == "local" else { throw Self.invalid("Copilot already has a different explicit bearer") }
        } else { additions.append("experimental_bearer_token = \"local\"") }
        if !additions.isEmpty {
            var insertion: [UInt8] = []
            if headerEnd > 0 && input[headerEnd - 1] != 10 { insertion += newline }
            for line in additions { insertion += Array(line.utf8) + newline }
            edits.append(Edit(range: headerEnd..<headerEnd, replacement: Data(insertion)))
        }
        return edits
    }

    private static func removingStatementPreservingComment(_ statement: [UInt8], in range: Range<Int>) -> Edit {
        let visible = withoutComment(statement)
        guard visible.count < statement.count else { return Edit(range: range, replacement: Data()) }
        // Leave inline comments and their existing whitespace as comment-only
        // lines. Standalone comment/blank statements never enter this helper.
        let indentation = statement.prefix { $0 == 9 || $0 == 32 }
        var suffixStart = visible.count
        while suffixStart > 0 && [9, 32].contains(statement[suffixStart - 1]) { suffixStart -= 1 }
        return Edit(range: range, replacement: Data(Array(indentation) + Array(statement[suffixStart...])))
    }

    private static func assignment(_ visible: [UInt8], in range: Range<Int>) throws -> Assignment {
        guard let equals = equalsOffset(visible) else { throw invalid("expected a key = value assignment") }
        let keys = try keyPath(String(decoding: visible[..<equals], as: UTF8.self))
        var begin = equals + 1, end = visible.count
        while begin < end && [9, 10, 13, 32].contains(visible[begin]) { begin += 1 }
        while end > begin && [9, 10, 13, 32].contains(visible[end - 1]) { end -= 1 }
        guard begin < end else { throw invalid("missing value") }
        return Assignment(keys: keys, value: String(decoding: visible[begin..<end], as: UTF8.self),
            valueRange: (range.lowerBound + begin)..<(range.lowerBound + end), statementRange: range)
    }

    private static func simpleString(_ value: String) throws -> String {
        let input = Array(value.utf8)
        guard input.count >= 2, let quote = input.first, [34, 39].contains(quote), input.last == quote,
              input.dropFirst().dropLast().allSatisfy({ $0 >= 32 && $0 != 127 && $0 != quote && $0 != 92 }) else {
            throw invalid("expected a simple quoted string in a managed Copilot field")
        }
        return String(decoding: input.dropFirst().dropLast(), as: UTF8.self)
    }

    private static func singleStringArray(_ value: String) throws -> String {
        guard value.hasPrefix("["), value.hasSuffix("]") else { throw invalid("expected local auth args array") }
        var item = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if item.hasSuffix(",") { item = String(item.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return try simpleString(item)
    }

    private static func invalid(_ message: String) -> SourceFileError { .invalidConfiguration(message) }

    private static func keyPath(_ text: String) throws -> [String] {
        let input = Array(text.utf8)
        var i = 0
        var keys: [String] = []
        while i < input.count {
            while i < input.count && [9, 32].contains(input[i]) { i += 1 }
            guard i < input.count else { throw invalid("empty key segment") }
            let start: Int
            let end: Int
            if [34, 39].contains(input[i]) {
                let quote = input[i]
                i += 1; start = i
                while i < input.count && input[i] != quote {
                    guard input[i] != 92 && input[i] >= 32 else { throw invalid("escaped or control characters in keys are unsupported") }
                    i += 1
                }
                guard i < input.count else { throw invalid("unterminated quoted key") }
                end = i; i += 1
            } else {
                start = i
                while i < input.count && ((48...57).contains(input[i]) || (65...90).contains(input[i]) || (97...122).contains(input[i]) || input[i] == 45 || input[i] == 95) { i += 1 }
                end = i
            }
            guard start < end else { throw invalid("empty or invalid key") }
            keys.append(String(decoding: input[start..<end], as: UTF8.self))
            while i < input.count && [9, 32].contains(input[i]) { i += 1 }
            if i < input.count {
                guard input[i] == 46 else { throw invalid("invalid key separator") }
                i += 1
                guard i < input.count else { throw invalid("empty key segment") }
            }
        }
        guard !keys.isEmpty else { throw invalid("empty key") }
        return keys
    }

    private static func equalsOffset(_ input: [UInt8]) -> Int? {
        var quote: UInt8?
        for i in input.indices {
            if let current = quote { if input[i] == current { quote = nil } }
            else if [34, 39].contains(input[i]) { quote = input[i] }
            else if input[i] == 61 { return i }
        }
        return nil
    }

    private static func withoutComment(_ input: [UInt8]) -> [UInt8] {
        var quote: UInt8?
        var escaped = false
        for i in input.indices {
            if escaped { escaped = false; continue }
            if let current = quote {
                if current == 34 && input[i] == 92 { escaped = true }
                else if input[i] == current { quote = nil }
            } else if [34, 39].contains(input[i]) { quote = input[i] }
            else if input[i] == 35 { return Array(input[..<i]) }
        }
        return input
    }

    /// Lexically isolate statements so table-looking text inside multiline strings,
    /// arrays, comments, and inline tables cannot change the root/table boundary.
    private static func statements(_ input: [UInt8]) throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0, i = 0
        var quote: UInt8?
        var multiline = false, escaped = false, comment = false
        var brackets: [UInt8] = []
        while i < input.count {
            let byte = input[i]
            if comment {
                if byte == 10 { comment = false }
            } else if let current = quote {
                if escaped { escaped = false }
                else if current == 34 && byte == 92 { escaped = true }
                else if byte == current {
                    if multiline {
                        if i + 2 < input.count && input[i + 1] == current && input[i + 2] == current {
                            var end = i + 3
                            while end < input.count && input[end] == current { end += 1 }
                            // TOML allows one or two content quotes immediately
                            // before the three closing quotes. Consume all 4/5;
                            // leaving them behind would open a phantom string.
                            guard end - i <= 5 else { throw invalid("too many quotes at a multiline string boundary") }
                            quote = nil; multiline = false; i = end - 1
                        }
                    } else { quote = nil }
                } else if !multiline && (byte == 10 || byte == 13) { throw invalid("unterminated single-line string") }
            } else if byte == 35 { comment = true }
            else if [34, 39].contains(byte) {
                quote = byte
                if i + 2 < input.count && input[i + 1] == byte && input[i + 2] == byte {
                    multiline = true; i += 2
                }
            } else if byte == 91 || byte == 123 { brackets.append(byte) }
            else if byte == 93 || byte == 125 {
                guard brackets.popLast() == (byte == 93 ? 91 : 123) else { throw invalid("unbalanced brackets") }
            }
            if byte == 10 && quote == nil && brackets.isEmpty {
                ranges.append(start..<(i + 1)); start = i + 1
            }
            i += 1
        }
        guard quote == nil && brackets.isEmpty else { throw invalid("unterminated string or bracket") }
        if start < input.count { ranges.append(start..<input.count) }
        return ranges
    }
}

struct SourceFileSnapshot: Sendable {
    let url: URL
    let data: Data?
    let identity: SourceFileIdentity?

    static func read(_ url: URL) throws -> SourceFileSnapshot {
        let before = try SourceFileIdentity.read(url)
        guard before != nil else { return SourceFileSnapshot(url: url, data: nil, identity: nil) }
        let data = try Data(contentsOf: url, options: [.uncached])
        guard before == (try SourceFileIdentity.read(url)) else { throw SourceFileError.changed(url.lastPathComponent) }
        return SourceFileSnapshot(url: url, data: data, identity: before)
    }

    func requireUnchanged() throws {
        let current = try Self.read(url)
        guard current.identity == identity && current.data == data else { throw SourceFileError.changed(url.lastPathComponent) }
    }

    /// The application is closed and switcher processes hold a shared advisory lock.
    /// Check bytes + inode/timestamps again immediately before the atomic rename.
    /// Non-cooperating filesystem writers cannot be locked out by a userspace CAS.
    func replace(with bytes: Data?, privateFile: Bool = true) throws -> SourceFileSnapshot {
        try requireUnchanged()
        guard bytes != data else { return self }
        guard let bytes else {
            try requireUnchanged()
            guard Darwin.unlink(url.path) == 0 else { throw Self.posixError() }
            return try Self.read(url)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".source-switch-\(UUID()).tmp")
        let mode = privateFile ? mode_t(0o600) : (identity?.mode ?? mode_t(0o600))
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.posixError() }
        var open = true
        defer {
            if open { _ = Darwin.close(fd) }
            _ = Darwin.unlink(temporary.path)
        }
        try bytes.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: position), buffer.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.posixError() }
                position += count
            }
        }
        guard Darwin.fchmod(fd, mode) == 0, Darwin.fsync(fd) == 0 else { throw Self.posixError() }
        guard Darwin.close(fd) == 0 else { open = false; throw Self.posixError() }
        open = false
        try requireUnchanged()
        // RENAME_EXCL also protects the previously-absent destination atomically.
        let status = identity == nil
            ? Darwin.renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL))
            : Darwin.rename(temporary.path, url.path)
        guard status == 0 else { throw Self.posixError() }
        let installed = try Self.read(url)
        guard installed.data == bytes else { throw SourceFileError.changed(url.lastPathComponent) }
        return installed
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

struct SourceFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let mode: mode_t

    static func read(_ url: URL) throws -> SourceFileIdentity? {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw SourceFileError.unsafe(url.lastPathComponent) }
        return SourceFileIdentity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec,
            mode: value.st_mode & 0o777)
    }
}
