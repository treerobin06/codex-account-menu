import SwiftUI
import SwitcherCore

/// One compact entry to the request inspector. A WS timestamp describes its
/// connection lifecycle, never the time of a model turn inside that connection.
struct APIActivitySummaryCard: View {
    let summary: APIActivitySummary
    let openDetails: () -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Button(action: openDetails) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: summary.isFailure ? "exclamationmark.circle" : "arrow.triangle.branch")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(summary.isFailure ? Color.orange : Color.accentColor)
                        .frame(width: 25)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text("最近 API 活动")
                            Spacer(minLength: 2)
                            Text(timeLabel(at: context.date)).monospacedDigit()
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        Text(summary.headline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(secondaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovered ? 0.055 : 0.025))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.13 : 0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("最近 API 活动，\(summary.headline)，\(timeLabel(at: context.date))，\(secondaryLine)")
            .accessibilityHint(summary.latest?.threadUUID == nil ? "打开对话与请求" : "打开详情并定位关联对话")
            .help(completeDescription)
        }
    }

    private var secondaryLine: String {
        if let title = summary.conversationTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "对话：" + title
        }
        return summary.detail
    }

    private var completeDescription: String {
        var lines = [summary.headline, summary.detail]
        if let error = summary.error, !error.isEmpty { lines.append(error) }
        if let title = summary.conversationTitle { lines.append("关联对话：" + title) }
        if let date = summary.timestamp {
            lines.append("记录时间：" + date.formatted(date: .abbreviated, time: .standard))
        }
        if let checkedAt = summary.checkedAt {
            lines.append("状态检查：" + checkedAt.formatted(date: .abbreviated, time: .standard))
        }
        lines.append("点击查看对话与请求；传输状态不代表模型回答完成或账单扣减。")
        return lines.joined(separator: "\n")
    }

    private func timeLabel(at now: Date) -> String {
        guard let record = summary.latest else { return "查看详情" }
        guard let timestamp = summary.timestamp else { return "时间未确认" }
        let seconds = now.timeIntervalSince(timestamp)
        guard seconds >= -5 else { return "时间待核对" }
        let relative: String
        if seconds < 60 { relative = "刚刚" }
        else if seconds < 3600 { relative = "\(Int(seconds / 60)) 分钟前" }
        else if seconds < 86_400 { relative = "\(Int(seconds / 3600)) 小时前" }
        else { relative = "\(Int(seconds / 86_400)) 天前" }
        if summary.error != nil { return "上次记录 · " + relative }
        switch record.phase {
        case "websocket_open": return relative + "建立 · 连接中"
        case "forwarding": return relative + "开始连接"
        case "http_response": return relative + "开始 · 传输中"
        case "http_finished": return relative + "结束"
        case "http_closed", "websocket_closed": return relative + "关闭"
        case "websocket_rejected": return relative + "被拒绝"
        case "transport_error": return relative + "失败"
        default: return relative + "记录"
        }
    }
}
