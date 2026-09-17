import SwiftUI

struct SourceRow<Content: View>: View {
    let name: String
    let subtitle: String?
    let symbol: String
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    var allowReselect = false
    var accessory: AnyView? = nil
    var helpText: String? = nil
    @ViewBuilder let content: Content
    @State private var hovered = false

    private var rowHelp: String {
        let action = selected ? "当前选择的推理来源；以实际请求验证为准" : "切换前将确认退出并重新打开 Codex"
        guard let helpText, !helpText.isEmpty else { return action }
        return action + "\n\n" + helpText
    }

    var body: some View {
        Button {
            if !selected || allowReselect { select() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 23)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(selected ? (allowReselect ? "连接身份" : "当前") : "切换")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected ? Color.secondary : Color.accentColor)
                }
                .padding(.trailing, accessory == nil ? 0 : 26)

                content
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(name)\(selected ? "，当前使用" : "，切换账号")")
        .help(rowHelp)
        .accessibilityHint(rowHelp)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.065) : Color.primary.opacity(hovered ? 0.045 : 0.025))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.18) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            // The menu is a sibling of the source button, so opening it cannot
            // also select the source underneath it.
            if let accessory {
                accessory
                    .disabled(disabled)
                    .padding(11)
            }
        }
        .onHover { hovered = $0 }
    }
}

struct UsageMeter: View {
    let title: String
    let percent: Double
    let resetsAt: Date?

    private var boundedPercent: Double { min(100, max(0, percent)) }
    private var percentageText: String { boundedPercent.formatted(.number.precision(.fractionLength(0...1))) }
    private var tint: Color { boundedPercent <= 10 ? .red : boundedPercent <= 25 ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("\(percentageText)%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            ProgressView(value: boundedPercent, total: 100)
                .tint(tint)
                .allowsHitTesting(false)
                .accessibilityLabel(title)
                .accessibilityValue("剩余百分之\(percentageText)")
            if let resetsAt {
                Text("重置于 \(MenuDate.display(resetsAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SmallNotice: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if warning {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            Text(text)
                .lineLimit(3)
                .help(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

enum MenuDate {
    static func display(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天 " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }
}

enum MenuText {
    static func copilotPlan(_ value: String) -> String {
        switch value.lowercased() {
        case "enterprise", "copilot_enterprise": "Enterprise"
        case "business", "copilot_business": "Business"
        case "individual": "个人方案"
        case "pro", "copilot_pro": "Pro"
        case "pro_plus", "copilot_pro_plus": "Pro+"
        case "free", "copilot_free": "Free"
        case "student": "学生方案"
        default: value.replacingOccurrences(of: "_", with: " ").localizedCapitalized
        }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
