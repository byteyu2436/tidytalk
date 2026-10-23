import AppKit
import Testing
@testable import TidytalkApp

/// 粘贴后恢复剪贴板（C1、I4）。用独立命名的剪贴板，不碰用户的系统剪贴板；
/// PasteService 记着上一次还没恢复的粘贴，所以这些测试要依次执行。
@MainActor
@Suite(.serialized) struct PasteServiceTests {
    let pasteboard = NSPasteboard(name: .init("app.tidytalk.tests.\(UUID().uuidString)"))

    private func reset() {
        pasteboard.clearContents()
        pasteboard.setString("用户原来的内容", forType: .string)
    }

    /// 文字、富文本、图片、文件，两项内容，保存再恢复后完全一致（原 `--clipboard-test`）。
    @Test func snapshotRestoresEveryItemAndType() throws {
        let first = NSPasteboardItem()
        first.setString("原来的文字", forType: .string)
        first.setData(try NSAttributedString(string: "富文本").data(
            from: NSRange(location: 0, length: 3), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
            forType: .rtf)
        first.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
        let second = NSPasteboardItem()
        second.setString(URL(fileURLWithPath: "/Applications/Safari.app").absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        func dump() -> [[String: Data]] {
            (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } })
            }
        }
        let before = dump()
        let saved = PasteService.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Tidytalk 临时写入", forType: .string)
        PasteService.restore(saved, to: pasteboard)
        #expect(before.count == 2)
        #expect(dump() == before)
        pasteboard.releaseGlobally()
    }

    @Test func c1PasteReturnsImmediatelyAndSlowReaderStillGetsText() async {
        reset()
        var readText: String?
        let start = Date()
        await PasteService.paste("新的说话内容", pasteboard: pasteboard) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { readText = pasteboard.string(forType: .string) }
        }
        #expect(Date().timeIntervalSince(start) < 0.2)
        await PasteService.waitUntilRestored()
        #expect(readText == "新的说话内容")
        #expect(pasteboard.string(forType: .string) == "用户原来的内容")
        pasteboard.releaseGlobally()
    }

    @Test func c1UnreadPasteIsRestoredAfterTimeout() async {
        reset()
        await PasteService.paste("没人读的内容", pasteboard: pasteboard) {}
        await PasteService.waitUntilRestored()
        #expect(pasteboard.string(forType: .string) == "用户原来的内容")
        pasteboard.releaseGlobally()
    }

    @Test func c1NewCopyIsNotOverwritten() async {
        reset()
        await PasteService.paste("会被替换的内容", pasteboard: pasteboard) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString("用户刚复制的", forType: .string)
            }
        }
        await PasteService.waitUntilRestored()
        #expect(pasteboard.string(forType: .string) == "用户刚复制的")
        pasteboard.releaseGlobally()
    }

    @Test func i4FinishPendingRestoresBeforeNextSnapshot() async {
        reset()
        await PasteService.paste("刚说的文字", pasteboard: pasteboard) {}
        // 语音改写模拟 ⌘C 前先恢复，快照里是用户自己的内容
        PasteService.finishPending()
        #expect(pasteboard.string(forType: .string) == "用户原来的内容")
        let snapshot = PasteService.snapshot(pasteboard)
        #expect(snapshot.first?.contains { $0.0 == .string && $0.1 == Data("用户原来的内容".utf8) } == true)
        await PasteService.waitUntilRestored()
        pasteboard.releaseGlobally()
    }
}
