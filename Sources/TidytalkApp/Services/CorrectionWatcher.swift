import AppKit
import ApplicationServices
import TidytalkCore

/// 粘贴后留意用户有没有手动改掉某个词（例如把"克劳德"改成"Claude"），发现后交给用户确认是否加入词库。
///
/// 通过辅助功能读取输入框里的文字，只在粘贴后的一分半钟内、同一个输入框里比较，不保存任何内容。
@MainActor
final class CorrectionWatcher {
    /// 发现改动时回调；用户确认后才会加入词库。
    var onCorrections: (([WordCorrection]) -> Void)?

    private static let pollInterval: Duration = .seconds(2)
    /// 粘贴后等目标应用把文字放进输入框，再读第一次。
    private static let settleDelay: Duration = .milliseconds(500)
    private static let watchDuration: TimeInterval = 90
    /// 前后各取一段文字，用来在用户修改后重新找到粘贴的那段。
    private static let anchorLength = 24
    private static let maxFieldLength = 50_000

    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
    }

    func watch(pasted: String) {
        stop()
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        task = Task { [weak self] in
            // 等目标应用把粘贴的文字放进输入框
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let element = Self.focusedElement(),
                  let initial = Self.value(of: element),
                  let anchors = Self.anchors(for: text, in: initial, caret: Self.caret(of: element))
            else { return }

            let deadline = Date().addingTimeInterval(Self.watchDuration)
            var last = text
            var stableRounds = 0
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard let value = Self.value(of: element),
                      let region = Corrections.region(in: value, before: anchors.before, after: anchors.after)
                else { return }
                if region == last {
                    stableRounds += 1
                } else {
                    last = region
                    stableRounds = 0
                }
                // 改过之后停手 4 秒左右，认为改完了
                if last != text, stableRounds >= 2 { break }
            }
            guard !Task.isCancelled, last != text else { return }
            let corrections = Corrections.find(original: text, edited: last.trimmingCharacters(in: .whitespacesAndNewlines))
            if !corrections.isEmpty { self?.onCorrections?(corrections) }
        }
    }

    // MARK: - 辅助功能

    private static func focusedElement() -> AXUIElement? {
        // 密码框不读
        guard let element = Accessibility.focusedElement(), !Accessibility.isSecureField(element) else { return nil }
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String, string.utf16.count <= maxFieldLength
        else { return nil }
        return string
    }

    /// 光标位置（UTF-16），读不到时为 nil。
    private static func caret(of element: AXUIElement) -> Int? {
        Accessibility.selectedRange(element)?.location
    }

    /// 找到刚粘贴的文字（优先在光标前面），取它前后的一段文字作为定位用的锚点。
    private static func anchors(for text: String, in value: String, caret: Int?) -> (before: String, after: String)? {
        let range: Range<String.Index>?
        if let caret {
            let caretIndex = String.Index(utf16Offset: min(caret, value.utf16.count), in: value)
            range = value.range(of: text, options: .backwards, range: value.startIndex..<caretIndex)
                ?? value.range(of: text, options: .backwards)
        } else {
            range = value.range(of: text, options: .backwards)
        }
        guard let range else { return nil }
        let before = String(value[..<range.lowerBound].suffix(anchorLength))
        let after = String(value[range.upperBound...].prefix(anchorLength))
        return (before, after)
    }
}
