import AppKit
import ApplicationServices

/// 辅助功能接口的公共部分：读取前台应用的焦点元素和属性。说话输入判断输入框、语音改写读选区、自动学词读输入框都用它。
@MainActor
enum Accessibility {
    /// 每次调用最多等多久。默认约 6 秒：目标应用卡死（转彩球）时 Tidytalk 也会跟着卡住。
    static let messagingTimeout: Float = 0.5

    /// 设置本应用所有辅助功能调用的超时，启动时调用一次（对系统级元素设置即对全部元素生效）。
    static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// 前台应用的焦点元素；同时返回错误码，Electron 应用需要据此再试一次。
    static func focusedElement(of app: AXUIElement) -> (AXError, AXUIElement?) {
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (error, nil) }
        return (error, (focused as! AXUIElement))
    }

    /// 前台应用的焦点元素。
    static func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return focusedElement(of: AXUIElementCreateApplication(pid)).1
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 选中的范围（没有选中时长度为 0，表示光标位置）。
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func isSecureField(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }
}
