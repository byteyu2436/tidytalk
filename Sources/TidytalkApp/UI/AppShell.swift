import AppKit
import SwiftUI

/// 主窗口（包括设置）的外框：左边是浅灰的侧边栏，右边是白底的内容区，中间一条细线（shadcn 的 Sidebar）。
/// 尺寸照设计稿的「布局规范」：侧边栏宽 240，顶部红绿灯一行高 52，和页头一样高。
struct AppShell<Sidebar: View, Content: View>: View {
    /// 侧边栏宽度，包括右边 1 点的细线
    static var sidebarWidth: CGFloat { 240 }

    /// 设置引导的侧边栏宽一些（260）
    var width: CGFloat = AppShell.sidebarWidth
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 红绿灯那一行，可以拖动窗口
                WindowDragArea().frame(height: Theme.headerHeight)
                sidebar()
            }
            .frame(width: width - 1)
            .frame(maxHeight: .infinity)
            .background(Theme.canvas)
            Rectangle().fill(Theme.border).frame(width: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
        }
        .background(Theme.panel)
        .ignoresSafeArea()
        .tint(Theme.accent)
        .toggleStyle(ShadcnSwitchStyle())
    }

    /// 窗口样式：隐藏标题栏，内容延伸到标题栏下面。加一条空的工具栏，标题栏变成 52 点高，
    /// 红绿灯在这一行里上下居中，和页头标题对齐。
    @MainActor
    static func configure(_ window: NSWindow, title: String) {
        window.title = title
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "TidytalkShell")
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(Theme.canvas)
    }
}

/// 侧边栏的一行：图标、名字、数量。高 32、圆角 6，选中时是浅灰底、名字加粗一点。
struct SidebarRow: View {
    let symbol: String
    let title: String
    /// 这个功能的颜色（见 `Theme.Tint`）
    var tint: Color = Theme.Tint.neutral
    var count: Int?
    var trailing: String?
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(selected ? Theme.bodyMedium : Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing, hovering {
                    KeyHint(trailing)
                } else if let count, count > 0 {
                    Text(verbatim: String(count)).font(Theme.small).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 侧边栏顶部：应用图标、名字和一句说明，高 52。
struct SidebarBrand: View {
    var subtitle: String = String(localized: "在这台 Mac 上识别")

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Tidytalk").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

/// 内容面板顶部的一行：高 52，左右边距 32（和内容区对齐），下面一条细线。
/// 左边是位置（「首页」或「资料库 › 标题」），右边是搜索框或图标按钮。
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, Theme.pagePadding)
        .frame(height: Theme.headerHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: @escaping () -> Leading) {
        self.init(leading: leading) { EmptyView() }
    }
}

/// 页头的标题（只有一层时）。
struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
    }
}

/// 详情页的页头左边：描边的返回按钮（⌘[），后面是位置“资料库 › 新版本发布时间”。
/// 按钮左边和内容区左边对齐；前面的“资料库”也可以点。
struct Breadcrumb: View {
    let parent: String
    let title: String
    let onBack: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            IconButton("chevron.left", helpText: String(localized: "返回\(parent)（⌘[）"), outlined: true, action: onBack)
                .keyboardShortcut("[", modifiers: .command)
            Button(action: onBack) {
                Text(parent)
                    .font(Theme.body)
                    .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("返回\(parent)（⌘[）")
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text(title)
                .font(Theme.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 内容区：上 28、左右 32、下 32，各块之间 24（设计稿的 Body）。`scrolls` 为 false 时不滚动，
/// 用在里面自己有滚动列表的页面（会议详情、转写详情）。
struct PageBody<Content: View>: View {
    var scrolls = true
    var spacing: CGFloat = Theme.sectionGap
    @ViewBuilder let content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView {
                stack.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.pageTop)
            .padding(.bottom, Theme.pagePadding)
    }
}

/// 一块可以拖动窗口的空白（标题栏隐藏后，侧边栏顶部和页头用它拖动窗口，双击缩放）。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
