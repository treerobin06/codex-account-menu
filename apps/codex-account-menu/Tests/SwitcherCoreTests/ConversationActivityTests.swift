import Foundation
import Testing
@testable import SwitcherCore

struct ConversationActivityTests {
    @Test func latestPromptAndAnswerAreShownTogetherWithoutDroppingOlderPreview() {
        let messages = ["assistant", "user", "assistant", "user", "assistant"].enumerated().map {
            ConversationMessagePreview(id: String($0.offset), role: $0.element, text: String($0.offset), timestamp: nil)
        }
        let preview = ConversationPreview(messages: messages, limited: true)
        #expect(preview.recentMessages.map(\.id) == ["3", "4"])
        #expect(preview.earlierMessages.map(\.id) == ["0", "1", "2"])
        let pending = ConversationPreview(messages: Array(messages.prefix(4)), limited: true)
        #expect(pending.recentMessages.map(\.id) == ["3"])
        let empty = ConversationPreview(messages: [], limited: false)
        #expect(empty.recentMessages.isEmpty && empty.earlierMessages.isEmpty)
    }
    @Test func aSharedSessionDoesNotMisattributeForkedThreads() {
        let a = UUID(), b = UUID()
        let record = observation(thread: a.uuidString.lowercased(), session: b.uuidString)
        #expect(record.belongs(to: a))
        #expect(!record.belongs(to: b))
        #expect(!observation(thread: nil, session: a.uuidString).belongs(to: a))
        #expect(!observation(thread: "untrusted-not-an-id", session: a.uuidString).belongs(to: a))
        #expect(record.startedDate != nil)
        #expect(record.phaseLabel == "WebSocket 已连接")
        #expect(!record.phaseLabel.contains("完成"))
    }

    @Test func legacyRelayCannotLookLikeAnEnabledRecorder() throws {
        let data = Data("""
        {"protocolVersion":1,"pid":123,"instanceId":"fixture","host":"127.0.0.1","port":4142,
         "baseURL":"http://127.0.0.1:4142/v1","enabled":true,"activeRequests":0,
         "activeWebSockets":1,"testMode":true,"upstreamPort":4141}
        """.utf8)
        let relay = try JSONDecoder().decode(APIRelayStatus.self, from: data)
        #expect(relay.observationVersion == nil)
        let snapshot = ConversationActivitySnapshot(conversations: [], relay: relay)
        #expect(snapshot.observations.isEmpty)
        #expect(snapshot.recordingStatus.contains("API 转发已启用"))
        #expect(snapshot.recordingStatus.contains("逐对话记录尚未开始"))
        let summary = APIActivitySummary(relay: relay, checkedAt: .now)
        #expect(summary.headline == "API 转发运行中")
        #expect(summary.timestamp == nil)
        #expect(summary.detail.contains("1 条活动连接"))
    }

    @Test func summaryShowsTransportTimeAndKeepsStaleReadErrorsExplicit() {
        let now = Date()
        let record = observation(thread: UUID().uuidString, session: nil)
        let summary = APIActivitySummary(latest: record, checkedAt: now)
        #expect(summary.timestamp == record.startedDate)
        #expect(summary.timestamp != now)
        let stale = APIActivitySummary(latest: record, checkedAt: now, error: "fixture status unavailable")
        #expect(stale.headline == "API 状态暂不可用")
        #expect(stale.detail.contains("原时间"))
        #expect(stale.timestamp == record.startedDate)
        #expect(stale.isFailure)
    }

    private func observation(thread: String?, session: String?) -> RelayRequestObservation {
        RelayRequestObservation(id: UUID().uuidString, startedAt: "2026-09-16T12:00:00.123Z",
            updatedAt: "2026-09-16T12:00:01.123Z", threadID: thread, sessionID: session,
            transport: "websocket", phase: "websocket_open", statusCode: 101, route: "copilot")
    }
}
