import AppKit
import SwiftUI
import SwitcherCore

struct ConversationActivityView: View {
    @ObservedObject var model: MenuModel
    @State private var snapshot: ConversationActivitySnapshot?
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var refreshing = false
    @State private var preview: ConversationPreview?
    @State private var previewOwnerID: UUID?
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var previewRequestID = UUID()
    private let initialSelectionID: UUID?
    private let allowAutomaticSelection: Bool

    init(model: MenuModel, initialSelectionID: UUID? = nil, allowAutomaticSelection: Bool = true) {
        self.model = model
        self.initialSelectionID = initialSelectionID
        self.allowAutomaticSelection = allowAutomaticSelection
        _selectedID = State(initialValue: initialSelectionID)
    }

    private var selected: ConversationSummary? {
        snapshot?.conversations.first { $0.id == selectedID }
    }
    private var filtered: [ConversationSummary] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.conversations ?? []).filter {
            value.isEmpty || $0.title.localizedCaseInsensitiveContains(value)
                || $0.cwd.localizedCaseInsensitiveContains(value)
                || $0.id.uuidString.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isDemo ? "对话与请求 · 演示数据" : "对话与请求")
                        .font(.title2.weight(.semibold))
                    Text("选择一个对话，查看最近问答与中转记录")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
                .help("只读取本地记录和中转状态，不调用模型或刷新账号额度")
            }
            .padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("搜索标题或项目", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("搜索对话")
                        .padding(.horizontal, 12).padding(.top, 12)
                    Text("最近 \(snapshot?.conversations.count ?? 0) 个本地对话")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                    List(selection: $selectedID) {
                        ForEach(filtered) { conversation in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title.isEmpty ? "未命名对话" : conversation.title)
                                    .font(.body.weight(.medium)).lineLimit(2)
                                Text(projectName(conversation.cwd))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                let observed = !(snapshot?.observations(for: conversation.id).isEmpty ?? true)
                                if observed || snapshot?.relay?.observationVersion == 1 {
                                    Label(observed ? "有本机中转记录" : "暂无中转记录",
                                          systemImage: observed ? "arrow.triangle.branch" : "clock")
                                        .font(.caption2)
                                        .foregroundStyle(observed ? Color.accentColor : Color.secondary)
                                } else {
                                    Text(conversation.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .tag(conversation.id)
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 340)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = snapshot?.catalogError {
                            notice("本地对话目录暂时无法读取：" + error, warning: true)
                        }
                        if let selected {
                            detail(selected)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(refreshing ? "正在读取本地对话…" : initialSelectionID != nil ? "该对话不在最近列表中" : !allowAutomaticSelection ? "这条请求未关联到具体对话" : "选择一个对话")
                                    .font(.title3.weight(.medium))
                                Text("这里只读取已有记录，不迁移或修改聊天历史。")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 430)
            }
            Divider()
            HStack {
                Text("仅查看本地 · 不复制聊天库")
                Spacer()
                if let date = snapshot?.observedAt {
                    Text("读取于 \(date.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await refresh() }
        .task(id: selectedID) { await loadPreview() }
    }

    @ViewBuilder
    private func detail(_ conversation: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(conversation.title.isEmpty ? "未命名对话" : conversation.title)
                .font(.title2.weight(.semibold)).lineLimit(4).textSelection(.enabled)
            Text(conversation.cwd).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(String(conversation.id.uuidString.lowercased().prefix(8)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("复制对话 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(conversation.id.uuidString.lowercased(), forType: .string)
                }
                .buttonStyle(.borderless).font(.caption)
                Spacer()
                Text("更新 \(conversation.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("请求去向").font(.headline)
            if let snapshot {
                Text(snapshot.recordingStatus).font(.callout).foregroundStyle(.secondary)
                let records = snapshot.observations(for: conversation.id)
                if records.isEmpty {
                    notice(snapshot.relay?.observationVersion == 1
                        ? "本次运行尚无这个对话的中转记录；没有记录不代表使用了官方额度。"
                        : "已有问答可以在下方查看。要采集新请求，请在主面板点“启用记录…”，确认后会正常重开 Codex；过去的请求不会补造。")
                } else {
                    ForEach(records) { record in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: record.isTransportFailure ? "exclamationmark.circle" : "arrow.triangle.branch")
                                .foregroundStyle(record.isTransportFailure ? Color.orange : Color.accentColor).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("转发目标：Copilot · \(record.transportLabel)").font(.callout.weight(.medium))
                                Text(record.phaseLabel + (record.statusCode.map { " · HTTP \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.startedDate?.formatted(date: .abbreviated, time: .standard) ?? "时间未识别")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if snapshot.unassociatedCount > 0 {
                    Text("另有 \(snapshot.unassociatedCount) 条传输未关联到当前列表中的对话。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("记录按请求携带的对话 ID 关联。一次 WebSocket 连接可能包含多轮问答；连接成功不等于回答完成，也不代表账单扣减。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        Divider()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近问答").font(.headline)
                Spacer()
                if loadingPreview { ProgressView().controlSize(.small) }
            }
            Text("按需读取现有本地记录，最多 12 条；与上方传输记录未逐轮配对。")
                .font(.caption).foregroundStyle(.secondary)
            if previewOwnerID == conversation.id, let previewError { notice(previewError, warning: true) }
            if previewOwnerID == conversation.id, let preview {
                if preview.messages.isEmpty {
                    notice("最近一段记录中没有可预览的 Prompt 或回答。完整内容仍在 Codex 中。")
                }
                ForEach(preview.recentMessages) { message in messageCard(message) }
                if !preview.earlierMessages.isEmpty {
                    DisclosureGroup("更早的问答预览（\(preview.earlierMessages.count) 条）") {
                        VStack(spacing: 12) {
                            ForEach(preview.earlierMessages) { message in messageCard(message) }
                        }
                        .padding(.top, 10)
                    }
                    .font(.callout)
                }
                if preview.limited {
                    Text("只显示最近的部分记录，每条最多 2000 字符；完整内容仍在 Codex 中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func messageCard(_ message: ConversationMessagePreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == "user" ? "你的 Prompt" : "回答").font(.callout.weight(.semibold))
                Spacer()
                if let timestamp = message.timestamp {
                    Text(timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
                .buttonStyle(.borderless).font(.caption)
                .help("复制当前显示的预览文本；截断部分不会补读")
            }
            Text(message.text).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(message.role == "user" ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private func notice(_ text: String, warning: Bool = false) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.circle" : "info.circle")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? "未记录项目" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let value = await model.backend.readConversationActivity()
        guard !Task.isCancelled else { return }
        snapshot = value
        if allowAutomaticSelection, initialSelectionID == nil, !value.conversations.contains(where: { $0.id == selectedID }) {
            selectedID = value.conversations.first?.id
        } else {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        let requestID = UUID()
        previewRequestID = requestID
        let id = selectedID
        previewOwnerID = id
        preview = nil; previewError = nil
        guard let selected else { loadingPreview = false; return }
        loadingPreview = true
        do {
            let value = try await model.backend.readConversationPreview(selected)
            guard !Task.isCancelled, selectedID == id, previewRequestID == requestID else { return }
            preview = value
        } catch {
            guard !Task.isCancelled, selectedID == id, previewRequestID == requestID else { return }
            previewError = "本次预览无法读取：" + MenuBackend.safeError(error)
        }
        if selectedID == id, previewRequestID == requestID { loadingPreview = false }
    }
}
