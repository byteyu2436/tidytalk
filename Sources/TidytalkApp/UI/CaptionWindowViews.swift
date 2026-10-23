import AppKit
import SwiftUI
import TidytalkCore

// 字幕条的窗口、容器视图和点击判定，由 CaptionPanel 组装。

/// 字幕条上每一句的位置（文字视图的坐标，左上角为原点），用来判断鼠标在哪一句上。
@MainActor
@Observable
final class CaptionTargets {
    enum Target: Hashable {
        case sentence(Int)
        case partial
    }

    /// 布局时写入，不需要触发界面刷新。
    @ObservationIgnored var frames: [Target: CGRect] = [:]
    /// 鼠标停在某一句上时出现的"粘贴"按钮的位置。
    @ObservationIgnored var buttonFrames: [Target: CGRect] = [:]
    /// 鼠标所在的句子，高亮显示并出现"粘贴"按钮。
    var hovered: Target?

    func target(at point: CGPoint) -> Target? {
        frames.first { $0.value.insetBy(dx: -6, dy: -3).contains(point) }?.key
    }

    func pasteButton(at point: CGPoint) -> Target? {
        guard let hovered, let frame = buttonFrames[hovered], frame.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return hovered
    }
}

final class CaptionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 字幕条的底层视图：鼠标移入移出时显示、隐藏按钮；按住拖动整个字幕条。
final class CaptionContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    /// 鼠标在窗口里移动（窗口坐标），移出时为 nil。
    var onMove: ((NSPoint?) -> Void)?
    /// 按下后没有拖动就松开：当作点击（窗口坐标）。
    var onClick: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 面板永远不是活跃窗口，必须用 activeAlways 才收得到移入移出
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        onMove?(nil)
    }
    override func mouseMoved(with event: NSEvent) { onMove?(event.locationInWindow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let origin = window?.frame.origin
        window?.performDrag(with: event)
        if window?.frame.origin == origin {
            onClick?(event.locationInWindow)
        } else {
            onDragEnd?()
        }
    }
}

/// 只显示文字，鼠标事件交给底下的视图处理拖动。
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板不会成为活跃窗口，第一次点击就要响应按钮。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
