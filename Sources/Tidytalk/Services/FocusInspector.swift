import AppKit
import ApplicationServices

/// 判断当前焦点是不是可以输入文字的地方（输入框、文本区域、可编辑的网页内容等）。
@MainActor
enum FocusInspector {
    enum Result {
        case editable
        /// 确定没有可输入的地方（例如焦点在桌面、网页正文、列表、按钮上）。
        case notEditable
        /// 无法判断（应用没有提供焦点信息，或焦点元素的类型不认识），按可输入处理，照常粘贴。
        case unknown
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// 明确不能输入文字的元素。只有焦点落在这些元素上才判定为"没有输入框"，宁可多粘贴一次，也不要该粘贴时没粘贴。
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXScrollArea", "AXGroup",
        "AXWebArea", "AXImage", "AXStaticText", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXSlider", "AXToolbar", "AXSplitGroup", "AXTabGroup", "AXWindow", "AXLink",
    ]

    static func focusedInput() -> Result {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
        let app = AXUIElementCreateApplication(pid)
        var (error, element) = focusedElement(of: app)
        if error != .success {
            // Electron / Chromium 应用默认不提供辅助功能信息，按约定打开 AXManualAccessibility 后再取一次
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            (error, element) = focusedElement(of: app)
        }
        // 取不到焦点元素时无法判断（部分应用的输入框也不报告焦点），照常粘贴
        guard error == .success, let element else { return .unknown }
        let role = string(element, kAXRoleAttribute)

        if let role, textRoles.contains(role) { return .editable }
        // 网页里的可编辑内容、自绘的编辑器：能设置选区，或者在可编辑区域内
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }
        var ancestor: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ancestor) == .success,
           ancestor != nil {
            return .editable
        }
        if let role, nonTextRoles.contains(role) { return .notEditable }
        return .unknown
    }

    /// 开发用：描述当前焦点元素，排查判断结果。
    static func describeFocus() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "无前台应用" }
        let (error, element) = focusedElement(of: AXUIElementCreateApplication(front.processIdentifier))
        var lines = ["\(front.localizedName ?? "?") error=\(error.rawValue) result=\(focusedInput())"]
        if let element {
            for name in ["AXRole", "AXSubrole", "AXRoleDescription", "AXDescription", "AXEditableAncestor"] {
                var value: CFTypeRef?
                let r = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                lines.append("\(name)=\(r == .success ? String(describing: value!).prefix(60).description : "(\(r.rawValue))")")
            }
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            lines.append("attrs=" + ((names as? [String])?.joined(separator: ",") ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private static func focusedElement(of app: AXUIElement) -> (AXError, AXUIElement?) {
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (error, nil) }
        return (error, (focused as! AXUIElement))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
