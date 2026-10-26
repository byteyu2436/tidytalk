import AppKit

/// 设置和引导窗口使用的窗口：
/// - 打开时不自动把光标放进第一个输入框；
/// - 点击输入框以外的地方（空白、开关、按钮等）时，输入框失去焦点。
///
/// macOS 默认会把焦点给第一个可编辑的输入框，而且点击空白处不会结束编辑。
final class FocusFriendlyWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        clearFocusSoon()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView,
           !Self.isTextInput(content.hitTest(content.convert(event.locationInWindow, from: nil))) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    /// SwiftUI 会在视图出现后的下一轮才分配初始焦点，所以稍后再清一次。
    func clearFocusSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.isTextInput(self.firstResponder as? NSView) else { return }
            self.makeFirstResponder(nil)
        }
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSTextView { return true }
            if let field = v as? NSTextField, field.isEditable { return true }
            current = v.superview
        }
        return false
    }
}
