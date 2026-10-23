import Foundation

/// 个人词库：常用人名、产品名、专业术语。
///
/// SenseVoice 不支持热词引导，所以分两步提高准确率：
/// 1. 固定替换表在本地直接替换（例如"克劳德"总是替换成"Claude"），不依赖 AI；
/// 2. 词库放进 AI 整理的提示里，让模型把发音相近的错误识别纠正过来。
public enum Vocabulary {
    /// 提示词里最多带的词条数：每次请求都会整份发送，太多既浪费也会让模型为了用上词库去改句子。
    public static let promptLimit = 80

    /// 去掉空白和重复项，保持原有顺序。
    public static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// 按替换表一次性替换（不会把替换结果再次替换）。较长的词优先匹配；
    /// 纯英文词不区分大小写，并且只匹配完整单词（"ai" 不会替换 "email" 里的 ai）。
    public static func applyReplacements(_ replacements: [String: String], to text: String) -> String {
        let rules = replacements
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        guard !rules.isEmpty else { return text }

        var lookup: [String: String] = [:]
        let pattern = rules.map { from, to -> String in
            lookup[from.lowercased()] = to
            let escaped = NSRegularExpression.escapedPattern(for: from)
            return isLatin(from) ? "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])" : escaped
        }.joined(separator: "|")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let found = ns.substring(with: match.range)
            result += lookup[found.lowercased()] ?? found
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func isLatin(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.isASCII }
    }
}
