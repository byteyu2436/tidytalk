import AppKit
import SwiftUI

/// 界面的配色、字号和常用控件，参考 shadcn/ui：zinc 中性色，主色是接近黑（深色下接近白）的颜色，
/// 卡片是细边框的圆角矩形，按钮只放图标。功能用固定的颜色区分（见 `Tint`）。浅色和深色各一套，跟着系统外观切换。
/// 设计稿在 docs/design/tidytalk-redesign.pen。
enum Theme {
    // MARK: 颜色

    /// 侧边栏
    static let canvas = dynamic(light: rgb(0xFAFAFA), dark: rgb(0x111113))
    /// 内容区
    static let panel = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x09090B))
    /// 内容区里的卡片
    static let card = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x18181B))
    /// 标签页、提示条、图标方块的浅底（shadcn 的 muted）
    static let subtle = dynamic(light: rgb(0xF4F4F5), dark: rgb(0x27272A))
    static let border = dynamic(light: rgb(0xE4E4E7), dark: rgb(0x2E2E33))
    /// 输入框、选择框、描边按钮的边框（shadcn 的 input）
    static let borderStrong = dynamic(light: rgb(0xE4E4E7), dark: rgb(0x3F3F46))
    static let hover = dynamic(light: .black.withAlphaComponent(0.04), dark: .white.withAlphaComponent(0.06))
    /// 侧边栏选中的一行、按下时的底色（shadcn 的 sidebar-accent）
    static let selected = dynamic(light: rgb(0xF4F4F5), dark: rgb(0x27272A))
    /// 列表里鼠标停着的那一行（设计稿的 muted）
    static let rowHover = dynamic(light: rgb(0xF4F4F5), dark: rgb(0x27272A))
    /// 输入框聚焦时的外圈
    static let ring = dynamic(light: rgb(0xA1A1AA), dark: rgb(0x71717A))

    static let text = dynamic(light: rgb(0x09090B), dark: rgb(0xFAFAFA))
    static let secondaryText = dynamic(light: rgb(0x71717A), dark: rgb(0xA1A1AA))
    /// 时间、数量这类次要信息
    static let tertiaryText = dynamic(light: rgb(0xA1A1AA), dark: rgb(0x71717A))

    /// 主色（主要按钮的底色）：浅色下接近黑，深色下接近白
    static let accent = dynamic(light: rgb(0x18181B), dark: rgb(0xFAFAFA))
    /// 主色上的文字和图标
    static let accentForeground = dynamic(light: rgb(0xFAFAFA), dark: rgb(0x18181B))
    /// 主色的文字和图标（选中、链接）
    static let accentText = dynamic(light: rgb(0x18181B), dark: rgb(0xFAFAFA))
    static let danger = dynamic(light: rgb(0xDC2626), dark: rgb(0xF87171))
    static let warning = dynamic(light: rgb(0xCA8A04), dark: rgb(0xFACC15))
    static let success = dynamic(light: rgb(0x16A34A), dark: rgb(0x4ADE80))

    // MARK: 字号

    // 和设计稿的字号一一对应（docs/design 里的「布局规范」）

    /// 正文、列表行的标题、输入框
    static let body = Font.system(size: 14)
    static let bodyMedium = Font.system(size: 14, weight: .medium)
    static let bodySemibold = Font.system(size: 14, weight: .semibold)
    /// 卡片和提示条里的说明、标签页、选择框
    static let caption = Font.system(size: 13)
    static let captionMedium = Font.system(size: 13, weight: .medium)
    static let captionSemibold = Font.system(size: 13, weight: .semibold)
    /// 列表行的第二行、时间、属性标签
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let micro = Font.system(size: 11, weight: .medium)
    /// 会议记录、转写正文
    static let reading = Font.system(size: 14)
    /// 分组标题（最近、转写记录）、卡片标题
    static let heading = Font.system(size: 15, weight: .semibold)
    /// 空状态的标题
    static let emptyTitle = Font.system(size: 16, weight: .semibold)
    /// 页面标题（24 号，字距 −0.4）
    static let title = Font.system(size: 24, weight: .semibold)
    static let titleTracking: CGFloat = -0.4

    /// 颜色的意义。每个功能固定一种颜色，侧边栏、设置、空白页、标签上都一样，看颜色就知道是哪个功能；
    /// 状态：处理中黄、完成用主色、出错红、没做完灰。
    enum Tint {
        /// 会议、参会的人
        static let meeting = dynamic(light: rgb(0x2563EB), dark: rgb(0x60A5FA))
        /// 转写、识别模型、音频
        static let speech = dynamic(light: rgb(0x0D9488), dark: rgb(0x2DD4BF))
        /// AI：总结、配置 AI、语音改写
        static let ai = dynamic(light: rgb(0x7C3AED), dark: rgb(0xA78BFA))
        /// 说话输入、麦克风、正在录音
        static let dictation = dynamic(light: rgb(0xDC2626), dark: rgb(0xF87171))
        /// 词库、快捷短语
        static let vocabulary = dynamic(light: rgb(0xEA580C), dark: rgb(0xFB923C))
        /// 实时字幕
        static let captions = dynamic(light: rgb(0xDB2777), dark: rgb(0xF472B6))
        /// 最近记录；也表示"只在这台 Mac 上"
        static let history = dynamic(light: rgb(0x16A34A), dark: rgb(0x4ADE80))
        static let local = history
        /// 设置、日期、时长这类中性信息
        static let neutral = dynamic(light: rgb(0x80838C), dark: rgb(0x8E9199))
        /// 视频文件
        static let video = vocabulary

        static let recording = dictation
        static let progress = dynamic(light: rgb(0xCA8A04), dark: rgb(0xFACC15))
        static let done = accent
        static let failed = danger
    }

    /// 按钮、标签、侧边栏的一行
    static let radius: CGFloat = 6
    /// 输入框、选择框
    static let fieldRadius: CGFloat = 8
    /// 卡片、提示条
    static let cardRadius: CGFloat = 12

    // MARK: 布局（设计稿「布局规范」）

    /// 页头高度；侧边栏顶部红绿灯那一行也是这个高度，圆点和页头标题在同一条中线上
    static let headerHeight: CGFloat = 52
    /// 页头和内容区的左右边距（两者对齐）
    static let pagePadding: CGFloat = 32
    /// 内容区上边距
    static let pageTop: CGFloat = 28
    /// 内容区里各块之间
    static let sectionGap: CGFloat = 24
    /// 分组标题到下面的卡片
    static let titleGap: CGFloat = 10

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

/// 图标和文字挨得近一些（系统的 Label 间距偏大）。
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11.5, weight: .semibold))
            configuration.title
        }
    }
}

/// 只有图标的按钮（按钮上不放文字，说明和快捷键放在鼠标停留时的提示里）。
/// - 默认：灰色图标（或功能色），鼠标移上去出现浅底；
/// - `prominent`：彩色底、白色图标，用在这一处最主要的操作（保存、提交、开始录音）；
/// - `destructive`：鼠标移上去变红（删除、清空）。
struct IconButton: View {
    let symbol: String
    let help: Text
    /// 32：页头、卡片里；28：列表行里（设计稿的图标按钮）
    var size: CGFloat = 32
    var tint: Color?
    var prominent = false
    /// 带细边框的白底（shadcn 的 outline），用在卡片里的次要操作
    var outlined = false
    var destructive = false
    let action: () -> Void

    init(_ symbol: String, help: LocalizedStringKey, size: CGFloat = 32, tint: Color? = nil, prominent: Bool = false,
         outlined: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.init(symbol, help: Text(help), size: size, tint: tint, prominent: prominent, outlined: outlined,
                  destructive: destructive, action: action)
    }

    /// 说明是算出来的文字（已经翻译好的）时用这个。
    init(_ symbol: String, helpText: String, size: CGFloat = 32, tint: Color? = nil, prominent: Bool = false,
         outlined: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.init(symbol, help: Text(verbatim: helpText), size: size, tint: tint, prominent: prominent,
                  outlined: outlined, destructive: destructive, action: action)
    }

    private init(_ symbol: String, help: Text, size: CGFloat, tint: Color?, prominent: Bool, outlined: Bool,
                 destructive: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.tint = tint
        self.prominent = prominent
        self.outlined = outlined
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: prominent ? .semibold : .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle(tint: tint, prominent: prominent, outlined: outlined, destructive: destructive))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent = false
    var outlined = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, tint: tint, prominent: prominent, outlined: outlined,
                       destructive: destructive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let prominent: Bool
    let outlined: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                if outlined && !prominent {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.borderStrong)
                }
            }
            .shadow(color: .black.opacity(outlined && !prominent ? 0.05 : 0), radius: 1, y: 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var foreground: Color {
        if prominent { return tint == nil ? Theme.accentForeground : .white }
        if hovering && destructive { return Theme.danger }
        return tint ?? (hovering ? Theme.text : Theme.secondaryText)
    }

    private var background: Color {
        let pressed = configuration.isPressed
        if prominent { return (tint ?? Theme.accent).opacity(pressed ? 0.8 : hovering ? 0.9 : 1) }
        if outlined { return pressed ? Theme.selected : hovering ? Theme.subtle : Theme.panel }
        return pressed ? Theme.selected : hovering ? Theme.hover : .clear
    }
}

/// 只有图标的菜单按钮（导出、更多）。
struct IconMenu<Content: View>: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 32
    var tint: Color?
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    private var color: Color { tint ?? (hovering ? Theme.text : Theme.secondaryText) }

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
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
            .font(Theme.micro)
            .foregroundStyle(onAccent ? Theme.accentForeground.opacity(0.85) : Theme.secondaryText)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(onAccent ? Theme.accentForeground.opacity(0.18) : Theme.subtle,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                if !onAccent {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.border)
                }
            }
    }
}

// MARK: - 标签页、搜索框

/// 标签页（原始记录 / AI 总结，全部 / 说话 / 会议 / 转写）：浅灰底上，选中的那个是带阴影的白底（shadcn 的 Tabs）。
struct LinearTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var count: Int?
        /// 标题前的小图标（AI 总结前的紫色星星）
        var symbol: String?
        var tint: Color?
    }

    @Binding var selection: Value
    let items: [Item]
    /// 设置行里用的小一号（高 32，和选择框一样高）
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 2 : 0) {
            ForEach(items, id: \.value) { item in
                TabButton(item: item, selected: item.value == selection, compact: compact) { selection = item.value }
            }
        }
        .padding(3)
        .frame(height: compact ? 32 : 36)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous))
    }

    private struct TabButton: View {
        let item: Item
        let selected: Bool
        let compact: Bool
        let action: () -> Void
        @ViewState private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let symbol = item.symbol {
                        // 没有功能色的图标跟着文字：选中的深、没选中的灰
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.tint ?? (selected || hovering ? Theme.text : Theme.secondaryText))
                    }
                    Text(item.title)
                        .font(Theme.captionMedium)
                        .foregroundStyle(selected || hovering ? Theme.text : Theme.secondaryText)
                    if let count = item.count {
                        Text(verbatim: String(count)).font(Theme.small).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, compact ? 10 : 12)
                .frame(maxHeight: .infinity)
                .background(selected ? Theme.panel : .clear,
                            in: RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous))
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1.5, y: 1)
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
    /// 没有输入时右边显示的快捷键
    var shortcut: String? = "⌘F"
    /// 每次变化时获得焦点（菜单的"在资料库里搜索"）
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .focused($focused)
                .onExitCommand { text = "" }
                .onChange(of: focusRequest) { focused = true }
                .onAppear { if focusRequest > 0 { focused = true } }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("清除")
            } else if let shortcut {
                KeyHint(shortcut)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: 32)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
            .strokeBorder(focused || !text.isEmpty ? Theme.ring : Theme.borderStrong))
    }
}

extension View {
    /// 带细边框的输入框（设计稿的 Input：高 36、圆角 8）。用在 `.textFieldStyle(.plain)` 的输入框上。
    /// `error` 时边框变红。
    func linearField(focused: Bool = false, error: Bool = false) -> some View {
        self
            .font(Theme.body)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                .strokeBorder(error ? Theme.danger : focused ? Theme.ring : Theme.borderStrong))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

/// 选择框（设计稿的 Select）：白底细边框，右边是上下箭头，点开是系统菜单。
struct SelectField<Value: Hashable>: View {
    @Binding var selection: Value
    /// 几组选项，组和组之间一条分隔线
    let sections: [[(value: Value, title: String)]]
    @ViewState private var hovering = false

    init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        _selection = selection
        sections = [options]
    }

    init(selection: Binding<Value>, sections: [[(value: Value, title: String)]]) {
        _selection = selection
        self.sections = sections.filter { !$0.isEmpty }
    }

    private var options: [(value: Value, title: String)] { sections.flatMap { $0 } }

    var body: some View {
        Menu {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.value) { option in
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 32)
            .background(hovering ? Theme.subtle : Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(Theme.borderStrong))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

// MARK: - 卡片、标签、提示

extension View {
    /// 卡片：白底（深色下略亮）、细边框、很淡的阴影，鼠标移上去边框加深。
    func cardStyle(hovering: Bool = false, radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hovering ? Theme.borderStrong : Theme.border))
            .shadow(color: .black.opacity(hovering ? 0.07 : 0.05), radius: hovering ? 6 : 1, y: 1)
    }
}

/// 资料库按天分组的标题：今天 4、昨天 3。
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.text)
            if let count {
                Text(verbatim: String(count)).font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// 分组标题（最近、转写记录）：15 号粗体，后面可以跟数量，右边放按钮；高 32，离下面的卡片 10。
struct GroupTitle<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
            if let count {
                Text(verbatim: String(count)).font(Theme.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(height: 32)
    }
}

extension GroupTitle where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// 页面标题：24 号粗体，下面一句灰色的说明（转写、词库、设置每一页）。
struct PageHeading: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.title).tracking(Theme.titleTracking).foregroundStyle(Theme.text)
            if let message {
                Text(message).font(Theme.body).foregroundStyle(Theme.secondaryText).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 属性标签：日期、时长、人数、来源。
struct PropertyChip: View {
    let symbol: String
    let text: String
    /// 图标的颜色（功能色）；不给时是灰色
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint ?? Theme.secondaryText)
            Text(text).font(Theme.smallMedium).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// 一排属性标签：从左往右排，这一行放不下就换到下一行，不截断（英文界面、窗口较窄时）。
struct ChipRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let used = arrange(subviews, width: proposal.width ?? .infinity).reduce(CGRect.zero) { $0.union($1) }
        return used.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing)
    }

    /// 每个标签按自己需要的宽度排；比一整行还宽的缩到一行宽。
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for var size in sizes {
            size.width = min(size.width, width)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

/// 提示条（设计稿的 Alert）：左边一个功能色图标，标题和一句说明，右边放按钮或进度条。
/// 用在还没准备好、处理进度、出错、需要下载模型、升级提示。
struct AlertBar<Actions: View>: View {
    let symbol: String
    var tint: Color = Theme.secondaryText
    /// 转圈的图标（处理中）
    var spinning = false
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if spinning {
                    LoopingAnimation(period: 1.2) { phase in
                        Image(systemName: symbol).rotationEffect(.degrees(phase * 360))
                    }
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                if let message {
                    Text(message).font(Theme.caption).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) { actions() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

extension AlertBar where Actions == EmptyView {
    init(symbol: String, tint: Color = Theme.secondaryText, spinning: Bool = false, title: String, message: String? = nil) {
        self.init(symbol: symbol, tint: tint, spinning: spinning, title: title, message: message) { EmptyView() }
    }
}

/// 空白页：一个带边框的小图标、标题、说明和按钮。
struct EmptyState<Actions: View>: View {
    let symbol: String
    /// 这个功能的颜色
    var tint: Color = Theme.Tint.neutral
    let title: String
    var message: String?
    /// 撑满可用的空间、内容居中（整页的空状态）；false 时只占自己的高度（卡片里的空状态）
    var fill = true
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, tint: Color = Theme.Tint.neutral, title: String, message: String? = nil, fill: Bool = true,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.fill = fill
        self.actions = actions
    }

    // 设计稿的 Empty State：图标方块 48、标题 16 号、说明 14 号灰色、最多一个按钮
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            Text(title).font(Theme.emptyTitle).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 372)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions() }.padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, tint: Color = Theme.Tint.neutral, title: String, message: String? = nil, fill: Bool = true) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, fill: fill) { EmptyView() }
    }
}

// MARK: - 状态图标

/// 状态图标：正在录音（红点）、处理中（黄色的圈，里面按进度填满）、完成（主色打勾）、
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
            case .progress(let fraction?):
                ZStack {
                    Circle().strokeBorder(Theme.Tint.progress, lineWidth: 1.5)
                    PieShape(fraction: fraction).fill(Theme.Tint.progress).padding(size * 0.22)
                }
            case .progress(nil):
                // 不知道进度：扇形一直转，看得出没有卡住
                ZStack {
                    Circle().strokeBorder(Theme.Tint.progress, lineWidth: 1.5)
                    LoopingAnimation(period: 1.2) { phase in
                        PieShape(fraction: 0.3).fill(Theme.Tint.progress).padding(size * 0.22)
                            .rotationEffect(.degrees(phase * 360))
                    }
                }
            case .done:
                Circle().fill(Theme.Tint.done).overlay {
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Theme.accentForeground)
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

/// 一直循环的动画（转圈、来回移动、闪光）。按时间算位置，不靠 onAppear，换了阶段再出现也照样在动；
/// 打开"减少动态效果"时停在开头的画面。`phase` 在 0...1 之间循环。
struct LoopingAnimation<Content: View>: View {
    var period: Double
    @ViewBuilder var content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(0)
        } else {
            TimelineView(.animation) { context in
                content(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
            }
        }
    }
}

extension View {
    /// 还在加载的占位图：一道光从左往右扫过。
    @ViewBuilder
    func shimmering(_ active: Bool) -> some View {
        if active {
            overlay {
                GeometryReader { proxy in
                    LoopingAnimation(period: 1.6) { phase in
                        LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: (phase * 1.6 - 0.6) * proxy.size.width)
                    }
                }
                .allowsHitTesting(false)
            }
        } else {
            self
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
    /// 设计稿：提示条和下载里 6，播放条 4
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtle)
                if let fraction {
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    LoopingAnimation(period: 1.8) { phase in
                        // 从左到右再回来，两头慢、中间快
                        Capsule().fill(tint)
                            .frame(width: proxy.size.width * 0.3)
                            .offset(x: proxy.size.width * 0.7 * (1 - cos(phase * 2 * .pi)) / 2)
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// 开关（shadcn 的 Switch）：打开时是主色的轨道，关着是浅灰，圆钮是底色。
/// 系统开关的颜色跟着强调色走，深色下主色接近白，圆钮会看不见，所以自己画。
struct ShadcnSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShadcnSwitch(configuration: configuration)
    }
}

private struct ShadcnSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        HStack(spacing: 10) {
            // 设置里的开关用 .labelsHidden()，名字和说明放在左边
            if labelsVisibility != .hidden {
                configuration.label
                Spacer(minLength: 0)
            }
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.borderStrong)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Theme.panel).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
                .animation(.snappy(duration: 0.15), value: configuration.isOn)
                .opacity(enabled ? 1 : 0.5)
                .onTapGesture { if enabled { configuration.isOn.toggle() } }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? Text("开") : Text("关"))
                .accessibilityAction { if enabled { configuration.isOn.toggle() } }
        }
    }
}
