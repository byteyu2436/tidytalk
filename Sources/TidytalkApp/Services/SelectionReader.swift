import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TidytalkCore

/// 读取当前应用里选中的文字，用于语音改写。
@MainActor
enum SelectionReader {
    /// 先用辅助功能接口直接读取；读不到时（网页、部分 Electron 应用）模拟 Cmd+C，读完恢复剪贴板。
    static func selectedText() async -> String? {
        let element = Accessibility.focusedElement()
        if let element, let text = Accessibility.string(element, kAXSelectedTextAttribute),
           TranscriptCleanup.hasContent(text) {
            return text
        }
        // 能读到选区、而且明确是空的（只是光标）：说明没有选中文字，不要再模拟 ⌘C。
        // VS Code、JetBrains 等编辑器没有选区时 ⌘C 会复制整行，改写后又插入一遍，同一行就出现两次
        if let element, let range = Accessibility.selectedRange(element), range.length == 0 { return nil }
        return await copySelection()
    }

    /// 模拟 ⌘C 后等目标应用写剪贴板：每 20 毫秒看一次，最多 15 次。
    private static let copyWaitStep: Duration = .milliseconds(20)
    private static let copyWaitSteps = 15

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        // 上一次说话输入粘贴后还没恢复剪贴板时，先恢复：否则快照里是刚说的文字，用户原来复制的内容就丢了
        PasteService.finishPending()
        let saved = PasteService.snapshot(pasteboard)
        let before = pasteboard.changeCount
        PasteService.postCommandShortcut("c", fallback: CGKeyCode(kVK_ANSI_C))

        // 最多等 300 毫秒让目标应用写入剪贴板
        var text: String?
        for _ in 0..<copyWaitSteps {
            try? await Task.sleep(for: copyWaitStep)
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
