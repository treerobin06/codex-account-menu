import Foundation

/// Auth metadata observed with the requested home's effective configuration.
/// No token is requested or exposed. `requiresOpenaiAuth` describes the provider's
/// requirements, not connectivity; callers must validate the auth method and the
/// concrete identity before treating a saved ChatGPT account as active.
public struct EffectiveAuthStatus: Equatable, Sendable {
    public let authMethod: String?
    public let requiresOpenaiAuth: Bool
    public let identity: AccountIdentity?

    public init(authMethod: String?, requiresOpenaiAuth: Bool, identity: AccountIdentity?) {
        self.authMethod = authMethod
        self.requiresOpenaiAuth = requiresOpenaiAuth
        self.identity = identity
    }
}

public enum EffectiveAuthStatusError: LocalizedError, Equatable, Sendable {
    case notSupported
    case inconsistentState

    public var errorDescription: String? {
        switch self {
        case .notSupported: "此账号客户端不支持按有效配置检查登录状态。"
        case .inconsistentState: "同一运行时返回的认证要求不一致，未确认登录状态。"
        }
    }
}
