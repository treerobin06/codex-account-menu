import Foundation

/// Finder/login-item launches do not inherit this Mac's terminal proxy exports.
/// Reuse the user's existing local proxy only for our owned account RPC helpers.
/// No system setting, Codex config file or model-provider selection is changed.
enum AccountProxyEnvironment {
    static let localProxy = "http://127.0.0.1:7897"
    static let proxyKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]

    static func applying(to inherited: [String: String]) -> [String: String] {
        // Even an explicitly empty variable is intentional caller policy.
        guard !proxyKeys.contains(where: { inherited[$0] != nil }) else { return inherited }
        var result = inherited
        for key in proxyKeys {
            result[key] = localProxy
        }
        for key in ["NO_PROXY", "no_proxy"] {
            let original = inherited[key] ?? inherited[key == "NO_PROXY" ? "no_proxy" : "NO_PROXY"] ?? ""
            var bypass = original.split(separator: ",").map(String.init)
            for host in ["localhost", "127.0.0.1", "::1"] where !bypass.contains(host) {
                bypass.append(host)
            }
            result[key] = bypass.joined(separator: ",")
        }
        return result
    }
}
