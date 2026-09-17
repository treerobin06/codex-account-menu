import Foundation

/// Metadata about one HTTP transport or WebSocket connection, not a model turn.
/// Neither a 200 response nor a 101 handshake proves a completed model answer.
public struct RelayRequestObservation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let startedAt: String
    public let updatedAt: String
    public let threadID: String?
    public let sessionID: String?
    public let transport: String
    public let phase: String
    public let statusCode: Int?
    public let route: String

    public init(id: String, startedAt: String, updatedAt: String, threadID: String?, sessionID: String?,
                transport: String, phase: String, statusCode: Int?, route: String) {
        self.id = id; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.threadID = threadID; self.sessionID = sessionID; self.transport = transport
        self.phase = phase; self.statusCode = statusCode; self.route = route
    }

    public var threadUUID: UUID? { threadID.flatMap(UUID.init(uuidString:)) }
    public var startedDate: Date? { Self.parseDate(startedAt) }
    public var updatedDate: Date? { Self.parseDate(updatedAt) }
    public var transportLabel: String { transport == "websocket" ? "WebSocket 连接" : "HTTP 请求" }
    public var isTransportFailure: Bool {
        ["transport_error", "websocket_rejected"].contains(phase) || (statusCode ?? 0) >= 400
    }
    public var phaseLabel: String {
        switch phase {
        case "forwarding": "正在连接中转"
        case "http_response": "已收到 HTTP 响应"
        case "http_finished": "HTTP 传输已结束"
        case "http_closed": "HTTP 连接已关闭"
        case "websocket_open": "WebSocket 已连接"
        case "websocket_closed": "WebSocket 已关闭"
        case "websocket_rejected": "WebSocket 握手被拒绝"
        case "transport_error": "传输失败"
        default: "状态未识别"
        }
    }

    /// A session can group several forked threads; never use it as a fallback.
    public func belongs(to thread: UUID) -> Bool { threadUUID == thread }

    private static func parseDate(_ value: String) -> Date? {
        guard value.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public struct ConversationActivitySnapshot: Sendable {
    public let observedAt: Date
    public let conversations: [ConversationSummary]
    public let relay: APIRelayStatus?
    public let catalogError: String?
    public let relayError: String?

    public init(observedAt: Date = Date(), conversations: [ConversationSummary], relay: APIRelayStatus?,
                catalogError: String? = nil, relayError: String? = nil) {
        self.observedAt = observedAt; self.conversations = conversations; self.relay = relay
        self.catalogError = catalogError; self.relayError = relayError
    }

    public var observations: [RelayRequestObservation] {
        guard relay?.observationVersion == 1 else { return [] }
        return Array((relay?.recentRequests ?? []).filter {
            $0.route == "copilot" && UUID(uuidString: $0.id) != nil
                && ["http", "websocket"].contains($0.transport)
        }.prefix(100))
    }

    public func observations(for thread: UUID) -> [RelayRequestObservation] {
        observations.filter { $0.belongs(to: thread) }
            .sorted { ($0.startedDate ?? .distantPast) > ($1.startedDate ?? .distantPast) }
    }

    public var unassociatedCount: Int {
        let ids = Set(conversations.map(\.id))
        return observations.filter { $0.threadUUID.map { !ids.contains($0) } ?? true }.count
    }

    public var recordingStatus: String {
        if let relayError { return "中转状态暂时无法读取：" + relayError }
        guard let relay else { return "本机中转未运行；这里暂时没有 API 请求记录" }
        guard relay.observationVersion == 1 else {
            if relay.observationVersion != nil { return "请求记录格式暂不兼容，需要核对转发版本" }
            if relay.enabled {
                return "API 转发已启用，当前 \(relay.activeRequests + relay.activeWebSockets) 条活动连接；逐对话记录尚未开始"
            }
            return "API 转发已停用；尚无逐对话请求记录"
        }
        return relay.enabled ? "记录本次中转运行期间的最近 100 条传输" : "本机中转已停用；保留本次运行已有记录"
    }
}

/// Compact main-panel state. Polling time is never presented as usage time.
public struct APIActivitySummary: Sendable {
    public let relay: APIRelayStatus?
    public let latest: RelayRequestObservation?
    public let conversationTitle: String?
    public let checkedAt: Date?
    public let error: String?

    public init(relay: APIRelayStatus? = nil, latest: RelayRequestObservation? = nil,
                conversationTitle: String? = nil, checkedAt: Date? = nil, error: String? = nil) {
        self.relay = relay; self.latest = latest; self.conversationTitle = conversationTitle
        self.checkedAt = checkedAt; self.error = error
    }

    public var isFailure: Bool { error != nil || latest?.isTransportFailure == true }
    public var isOpen: Bool {
        guard let latest else { return false }
        return ["forwarding", "http_response", "websocket_open"].contains(latest.phase)
    }
    public var timestamp: Date? { isOpen ? latest?.startedDate : latest?.updatedDate }
    public var headline: String {
        if error != nil { return "API 状态暂不可用" }
        if checkedAt == nil { return "正在读取 API 状态" }
        guard let relay else { return "本机 API 转发未运行" }
        if latest != nil {
            if isFailure { return "最近 API 传输失败" }
            return isOpen ? "API 连接中" : "最近 API 传输"
        }
        if relay.observationVersion != 1 { return relay.enabled ? "API 转发运行中" : "API 转发已停用" }
        return "尚无 API 传输记录"
    }
    public var detail: String {
        if error != nil { return "状态读取失败；已有记录保留原时间" }
        if let latest {
            return conversationTitle ?? latest.threadUUID.map { "对话 " + String($0.uuidString.lowercased().prefix(8)) }
                ?? "未关联到具体对话"
        }
        guard let relay else { return checkedAt == nil ? "仅读取本机，不查询账号额度" : "可查看已有的本地问答" }
        if relay.observationVersion == nil {
            return relay.enabled ? "\(relay.activeRequests + relay.activeWebSockets) 条活动连接 · 逐对话记录待启用" : "逐对话记录待启用"
        }
        return relay.observationVersion == 1 ? "点击查看本地对话与问答" : "记录格式暂不兼容"
    }
}

public extension ConversationPreview {
    /// Show the latest prompt and its following public answer first; older
    /// bounded previews stay available without copying another history store.
    var recentMessages: [ConversationMessagePreview] { Array(messages.dropFirst(recentMessageStart)) }
    var earlierMessages: [ConversationMessagePreview] { Array(messages.prefix(recentMessageStart)) }
    private var recentMessageStart: Int {
        messages.lastIndex(where: { $0.role == "user" }) ?? max(0, messages.count - 1)
    }
}
