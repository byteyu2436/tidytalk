import AppKit
import SwiftUI

/// 主窗口和设置窗口共用的外框：左边是侧边栏（窗口底色），右边的内容放在带细边框的圆角面板里。
/// 标题栏隐藏，红绿灯按钮浮在侧边栏左上角。
struct AppShell<Sidebar: View, Content: View>: View {
    static var sidebarWidth: CGFloat { 220 }

    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 红绿灯那一行，可以拖动窗口
                WindowDragArea().frame(height: 40)
                sidebar()
            }
            .frame(width: Self.sidebarWidth)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .tint(Theme.accent)
    }

    /// 窗口样式：隐藏标题栏，内容延伸到标题栏下面。
    @MainActor
    static func configure(_ window: NSWindow, title: String) {
        window.title = title
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(Theme.canvas)
    }
}

/// 侧边栏的一行：图标、名字、数量。选中时是浅灰底。
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
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(selected ? Theme.bodyMedium : Theme.body)
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(verbatim: String(count)).font(Theme.small).foregroundStyle(Theme.tertiaryText)
                }
                if let trailing {
                    KeyHint(trailing).opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 侧边栏顶部：应用图标和名字。
struct SidebarBrand: View {
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 20, height: 20)
            Text(verbatim: "Tidytalk").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle {
                Text(subtitle).font(Theme.body).foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

/// 内容面板顶部的一行：左边是标题或返回路径，右边是操作按钮，下面一条细线。
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: @escaping () -> Leading) {
        self.init(leading: leading) { EmptyView() }
    }
}

/// 页头的标题。
struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
    }
}

/// 返回路径：会议 › 测试会议。点前面的可以返回（⌘[）。
struct Breadcrumb: View {
    let parent: String
    let title: String
    let onBack: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Text(parent)
                    .font(Theme.bodyMedium)
                    .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut("[", modifiers: .command)
            .help("返回\(parent)（⌘[）")
            .padding(.leading, -6)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
