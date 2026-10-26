import AppKit
import SwiftUI

/// 界面的配色、字号和常用控件，参考 Linear：中性灰的底色，内容放在细边框的面板里，只用一个强调色，
/// 字号偏小、信息排得紧凑，鼠标移上去才出现次要操作。浅色和深色各一套，跟着系统外观切换。
enum Theme {
    // MARK: 颜色

    /// 窗口底色（侧边栏）
    static let canvas = dynamic(light: rgb(0xF3F3F5), dark: rgb(0x0C0C0E))
    /// 内容面板
    static let panel = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x151618))
    /// 面板上的卡片
    static let card = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1B1C1F))
    /// 输入框、标签、分组的浅底
    static let subtle = dynamic(light: rgb(0xF6F6F8), dark: rgb(0x1F2023))
    static let border = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.08))
    static let borderStrong = dynamic(light: .black.withAlphaComponent(0.15), dark: .white.withAlphaComponent(0.15))
    static let hover = dynamic(light: .black.withAlphaComponent(0.045), dark: .white.withAlphaComponent(0.05))
    static let selected = dynamic(light: .black.withAlphaComponent(0.075), dark: .white.withAlphaComponent(0.085))

    static let text = dynamic(light: rgb(0x1C1D21), dark: rgb(0xEDEEF0))
    static let secondaryText = dynamic(light: rgb(0x676A72), dark: rgb(0x9C9EA6))
    /// 时间、数量这类次要信息
    static let tertiaryText = dynamic(light: rgb(0x8A8C94), dark: rgb(0x6E7078))

    /// 强调色（按钮底色）：Linear 的靛蓝
    static let accent = dynamic(light: rgb(0x5E6AD2), dark: rgb(0x5E6AD2))
    /// 强调色的文字和图标：深色下调亮一些才看得清
    static let accentText = dynamic(light: rgb(0x5561CB), dark: rgb(0x9BA2F5))
    static let danger = dynamic(light: rgb(0xD1453B), dark: rgb(0xEB5F55))
    static let warning = dynamic(light: rgb(0xC9730A), dark: rgb(0xF0A040))
    static let success = dynamic(light: rgb(0x2E9E5B), dark: rgb(0x4CC27E))

    // MARK: 字号

    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let micro = Font.system(size: 11, weight: .medium)
    /// 会议记录、转写正文
    static let reading = Font.system(size: 14)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let title = Font.system(size: 22, weight: .semibold)

    /// 颜色的意义。每个功能固定一种颜色，侧边栏、设置、空白页、标签上都一样，看颜色就知道是哪个功能；
    /// 状态的颜色和 Linear 一致：处理中黄、完成靛蓝、出错红、没做完灰。
    enum Tint {
        /// 会议、参会的人
        static let meeting = dynamic(light: rgb(0x2F7FE6), dark: rgb(0x4EA7FC))
        /// 转写、识别模型、音频
        static let speech = dynamic(light: rgb(0x1797B0), dark: rgb(0x2CC0DA))
        /// AI：总结、配置 AI、语音改写
        static let ai = dynamic(light: rgb(0x7F56DE), dark: rgb(0xA88BFA))
        /// 说话输入、麦克风、正在录音
        static let dictation = dynamic(light: rgb(0xE0484D), dark: rgb(0xF2666A))
        /// 词库、快捷短语
        static let vocabulary = dynamic(light: rgb(0xDD7826), dark: rgb(0xF2994A))
        /// 实时字幕
        static let captions = dynamic(light: rgb(0xCF4A84), dark: rgb(0xF07CA8))
        /// 最近记录；也表示"只在这台 Mac 上"
        static let history = dynamic(light: rgb(0x2E9C66), dark: rgb(0x4CB782))
        static let local = history
        /// 设置、日期、时长这类中性信息
        static let neutral = dynamic(light: rgb(0x80838C), dark: rgb(0x8E9199))
        /// 视频文件
        static let video = vocabulary

        static let recording = dictation
        static let progress = dynamic(light: rgb(0xD19A06), dark: rgb(0xF2C94C))
        static let done = accent
        static let failed = danger
    }

    static let radius: CGFloat = 6
    static let cardRadius: CGFloat = 8
    /// 正文的最大宽度：窗口拉得很宽时一行也不会太长
    static let readableWidth: CGFloat = 760

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - 按钮

/// 按钮：主要（强调色底）、次要（细边框）、无边框、危险（红底）。
struct LinearButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        LinearButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct LinearButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LinearButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .labelStyle(TightLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(height: compact ? 24 : 28)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(hovering ? Theme.borderStrong : Theme.border)
                }
            }
            .shadow(color: .black.opacity(kind == .primary || kind == .danger ? 0.12 : kind == .secondary ? 0.04 : 0),
                    radius: 1, y: 0.5)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: .white
        case .secondary: Theme.text
        case .ghost: hovering ? Theme.text : Theme.secondaryText
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return Theme.accent.opacity(pressed ? 0.8 : hovering ? 0.9 : 1)
        case .danger: return Theme.danger.opacity(pressed ? 0.8 : hovering ? 0.9 : 1)
        case .secondary: return pressed ? Theme.selected : hovering ? Theme.subtle : Theme.card
        case .ghost: return pressed ? Theme.selected : hovering ? Theme.hover : .clear
        }
    }
}

/// 图标和文字挨得近一些（系统的 Label 间距偏大）。
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11.5, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == LinearButtonStyle {
    static var linear: LinearButtonStyle { LinearButtonStyle() }
    static func linear(_ kind: LinearButtonStyle.Kind, compact: Bool = false) -> LinearButtonStyle {
        LinearButtonStyle(kind: kind, compact: compact)
    }
}

/// 只有图标的按钮（按钮上不放文字，说明和快捷键放在鼠标停留时的提示里）。
/// - 默认：灰色图标（或功能色），鼠标移上去出现浅底；
/// - `prominent`：彩色底、白色图标，用在这一处最主要的操作（保存、提交、开始录音）；
/// - `destructive`：鼠标移上去变红（删除、清空）。
struct IconButton: View {
    let symbol: String
    let help: Text
    var size: CGFloat = 28
    var tint: Color?
    var prominent = false
    var destructive = false
    let action: () -> Void

    init(_ symbol: String, help: LocalizedStringKey, size: CGFloat = 28, tint: Color? = nil, prominent: Bool = false,
         destructive: Bool = false, action: @escaping () -> Void) {
        self.init(symbol, help: Text(help), size: size, tint: tint, prominent: prominent, destructive: destructive,
                  action: action)
    }

    /// 说明是算出来的文字（已经翻译好的）时用这个。
    init(_ symbol: String, helpText: String, size: CGFloat = 28, tint: Color? = nil, prominent: Bool = false,
         destructive: Bool = false, action: @escaping () -> Void) {
        self.init(symbol, help: Text(verbatim: helpText), size: size, tint: tint, prominent: prominent,
                  destructive: destructive, action: action)
    }

    private init(_ symbol: String, help: Text, size: CGFloat, tint: Color?, prominent: Bool, destructive: Bool,
                 action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.tint = tint
        self.prominent = prominent
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * (prominent ? 0.42 : 0.46), weight: prominent ? .bold : .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle(tint: tint, prominent: prominent, destructive: destructive))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, tint: tint, prominent: prominent, destructive: destructive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let prominent: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: .black.opacity(prominent ? 0.14 : 0), radius: 1, y: 0.5)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var foreground: Color {
        if prominent { return .white }
        if hovering && destructive { return Theme.danger }
        return tint ?? (hovering ? Theme.text : Theme.secondaryText)
    }

    private var background: Color {
        let pressed = configuration.isPressed
        if prominent { return (tint ?? Theme.accent).opacity(pressed ? 0.8 : hovering ? 0.9 : 1) }
        return pressed ? Theme.selected : hovering ? Theme.hover : .clear
    }
}

/// 空白页中间的大圆形按钮（开始会议、生成总结）。
struct RoundIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color = Theme.accent
    var size: CGFloat = 52
    /// 图标占按钮的比例；录音键用一个小的实心圆
    var glyph: CGFloat = 0.38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * glyph, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(tint))
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(RoundIconButtonStyle(tint: tint))
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct RoundIconButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        RoundIconButtonBody(configuration: configuration, tint: tint)
    }
}

private struct RoundIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .shadow(color: tint.opacity(hovering ? 0.45 : 0.3), radius: hovering ? 12 : 7, y: 3)
            .scaleEffect(configuration.isPressed ? 0.95 : hovering ? 1.05 : 1)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 && enabled }
            .animation(.spring(duration: 0.2), value: hovering)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
    }
}

/// 只有图标的菜单按钮（导出、更多）。
struct IconMenu<Content: View>: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 28
    var tint: Color?
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    private var color: Color { tint ?? (hovering ? Theme.text : Theme.secondaryText) }

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(color)
        .tint(color)
        .frame(width: size, height: size)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// 快捷键提示，例如 ⌃⌥M。
struct KeyHint: View {
    let keys: String
    var onAccent = false

    init(_ keys: String, onAccent: Bool = false) {
        self.keys = keys
        self.onAccent = onAccent
    }

    var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Theme.tertiaryText)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 17)
            .background(onAccent ? Color.white.opacity(0.18) : Theme.subtle,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                if !onAccent {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.border)
                }
            }
    }
}

// MARK: - 标签页、搜索框

/// 页头里的标签页（文件 / 链接，原始记录 / AI 总结）：选中的那个是带细边框的白底。
struct LinearTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var count: Int?
    }

    @Binding var selection: Value
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                TabButton(item: item, selected: item.value == selection) { selection = item.value }
            }
        }
    }

    private struct TabButton: View {
        let item: Item
        let selected: Bool
        let action: () -> Void
        @ViewState private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                    if let count = item.count {
                        Text(verbatim: String(count)).foregroundStyle(Theme.tertiaryText)
                    }
                }
                .font(Theme.smallMedium)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(selected ? Theme.card : hovering ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border)
                    }
                }
                .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 1, y: 0.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// 页头里的搜索框。
struct SearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var width: CGFloat = 220
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border))
    }
}

extension View {
    /// 带细边框的输入框（链接）。用在 `.textFieldStyle(.plain)` 的输入框上。
    func linearField(focused: Bool = false) -> some View {
        self
            .font(Theme.body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.borderStrong))
    }
}

// MARK: - 卡片、标签、提示

extension View {
    /// 面板上的卡片：白底（深色下略亮）、细边框，鼠标移上去边框加深。
    func cardStyle(hovering: Bool = false, radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hovering ? Theme.borderStrong : Theme.border))
            .shadow(color: .black.opacity(hovering ? 0.07 : 0.025), radius: hovering ? 6 : 1.5, y: hovering ? 2 : 1)
    }
}

/// 分组标题：今天 3、全部文件 5。
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.smallMedium).foregroundStyle(Theme.secondaryText)
            if let count {
                Text(verbatim: String(count)).font(Theme.small).foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

/// 属性标签：日期、时长、人数、来源。
struct PropertyChip: View {
    let symbol: String
    let text: String
    /// 图标的颜色（功能色）；不给时是灰色
    var tint: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint ?? Theme.tertiaryText)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.subtle, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// 页面里的提示条：处理进度、出错、需要下载模型。
struct Callout<Content: View>: View {
    var symbol: String?
    var tint: Color = Theme.secondaryText
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            }
            content()
        }
        .font(Theme.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// 空白页：一个带边框的小图标、标题、说明和按钮。
struct EmptyState<Actions: View>: View {
    let symbol: String
    /// 这个功能的颜色
    var tint: Color = Theme.Tint.neutral
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, tint: Color = Theme.Tint.neutral, title: String, message: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.22)))
                .padding(.bottom, 4)
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
            if let message {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            VStack(spacing: 8) { actions() }.padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, tint: Color = Theme.Tint.neutral, title: String, message: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}

// MARK: - 状态图标

/// 和 Linear 一样的状态图标：正在录音（红点）、处理中（黄色的圈，里面按进度填满）、完成（靛蓝打勾）、
/// 没做完（灰色虚线圈）、出错（红色感叹号）。
struct StatusIcon: View {
    enum Kind: Equatable {
        case recording
        /// 进度 0...1；nil 表示不知道进度
        case progress(Double?)
        case done
        case partial
        case failed
    }

    let kind: Kind
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch kind {
            case .recording:
                ZStack {
                    Circle().strokeBorder(Theme.Tint.recording, lineWidth: 1.5)
                    RecordingDot(size: size * 0.42)
                }
            case .progress(let fraction):
                ZStack {
                    Circle().strokeBorder(Theme.Tint.progress, lineWidth: 1.5)
                    PieShape(fraction: fraction ?? 0.5).fill(Theme.Tint.progress).padding(size * 0.22)
                }
            case .done:
                Circle().fill(Theme.Tint.done).overlay {
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                }
            case .partial:
                ZStack {
                    Circle().strokeBorder(Theme.Tint.neutral, style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 1.6]))
                    PieShape(fraction: 0.5).fill(Theme.Tint.neutral).padding(size * 0.22)
                }
            case .failed:
                Circle().fill(Theme.Tint.failed).overlay {
                    Image(systemName: "exclamationmark").font(.system(size: size * 0.55, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    var label: String {
        switch kind {
        case .recording: String(localized: "正在记录")
        case .progress: String(localized: "正在处理")
        case .done: String(localized: "已完成")
        case .partial: String(localized: "只完成了一部分")
        case .failed: String(localized: "出错了")
        }
    }
}

/// 从 12 点方向开始的扇形，`fraction` 是填满的比例。
struct PieShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard fraction > 0 else { return path }
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 带状态图标的属性标签（会议、转写详情页的第一个标签）。
struct StatusChip: View {
    let kind: StatusIcon.Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(kind: kind, size: 12)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.subtle, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// 底部的提示（已删除一句，可以撤销）。
struct Toast<Action: View>: View {
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(Theme.body).foregroundStyle(Theme.text)
            action()
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }
}

/// 细的进度条（系统的进度条在面板上太粗）。
struct ThinProgress: View {
    /// nil 时是来回移动的不确定进度
    let fraction: Double?
    var tint: Color = Theme.accent

    @ViewState private var phase = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.selected)
                if let fraction {
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: phase ? proxy.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}
