import Foundation

/// 更新提示里显示的更新说明。发布说明是中英文各写一份（中文在前），用空行分成几段；
/// 提示里只留和界面语言一致的那几段，免得说明太长。
public enum ReleaseNotes {
    /// - Parameter chinese: 界面是不是中文。
    /// - Returns: 只含一种语言的说明；说明里只有一种语言时原样返回。
    public static func localized(_ notes: String, chinese: Bool) -> String {
        let blocks = notes.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let chineseBlocks = blocks.filter(isChinese)
        let otherBlocks = blocks.filter { !isChinese($0) }
        guard !chineseBlocks.isEmpty, !otherBlocks.isEmpty else { return blocks.joined(separator: "\n\n") }
        return (chinese ? chineseBlocks : otherBlocks).joined(separator: "\n\n")
    }

    /// 一段里有汉字就算中文（英文说明里不会出现汉字）。
    static func isChinese(_ block: String) -> Bool {
        block.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
