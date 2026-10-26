import Foundation

/// 文件转写的一段结果：在音频里的起止时间和文字。
public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public var text: String

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 把转写结果导出成纯文本、SRT 字幕或 Markdown。
public enum TranscriptExport {
    public enum Format: String, CaseIterable, Sendable {
        case text = "txt"
        case srt
        case markdown = "md"

        public var title: String {
            switch self {
            case .text: String(localized: "纯文本（.txt）")
            case .srt: String(localized: "字幕（.srt）")
            case .markdown: "Markdown (.md)"
            }
        }
    }

    /// 停顿超过这个秒数时另起一段。
    static let paragraphGap: TimeInterval = 2

    public static func render(_ segments: [TranscriptSegment], as format: Format, title: String = "") -> String {
        let segments = segments.filter { !$0.text.isEmpty }
        switch format {
        case .text:
            return paragraphs(segments).joined(separator: "\n\n") + "\n"
        case .srt:
            return segments.enumerated().map { index, segment in
                "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(segment.end))\n\(segment.text)\n"
            }.joined(separator: "\n")
        case .markdown:
            var lines: [String] = []
            if !title.isEmpty { lines += ["# \(title)", ""] }
            lines += segments.map { "**\(clock($0.start))** \($0.text)" + "  " }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// 按停顿分段，段内的句子按中英文规则拼接。
    public static func paragraphs(_ segments: [TranscriptSegment]) -> [String] {
        var result: [[String]] = []
        var lastEnd: TimeInterval?
        for segment in segments where !segment.text.isEmpty {
            if let lastEnd, segment.start - lastEnd < paragraphGap, !result.isEmpty {
                result[result.count - 1].append(segment.text)
            } else {
                result.append([segment.text])
            }
            lastEnd = segment.end
        }
        return result.map(Transcript.join)
    }

    /// 00:01:02,345
    static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// 1:02 或 1:02:03
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
