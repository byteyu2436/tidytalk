import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TidytalkCore

/// 读取当前应用里选中的文字，用于语音改写。
@MainActor
enum SelectionReader {
    /// 先用辅助功能接口直接读取；读不到时（网页、部分 Electron 应用）模拟 Cmd+C，读完恢复剪贴板。
    static func selectedText() async -> String? {
        if let text = accessibilitySelection(), TranscriptCleanup.hasContent(text) { return text }
        return await copySelection()
    }

    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value)
            == .success
        else { return nil }
        return value as? String
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = PasteService.snapshot(pasteboard)
        let before = pasteboard.changeCount
        PasteService.postCommandShortcut("c", fallback: CGKeyCode(kVK_ANSI_C))

        // 最多等 300 毫秒让目标应用写入剪贴板
        var text: String?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { PasteService.restore(saved, to: pasteboard) }
        guard let text, TranscriptCleanup.hasContent(text) else { return nil }
        return text
    }
}
