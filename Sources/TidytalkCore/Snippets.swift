import Foundation

/// 快捷短语：说出某个短语时，直接输出预先设置好的内容（例如"我的邮箱" → 完整的邮箱地址）。
///
/// 只有整句话就是这个短语时才展开（忽略标点、空格和大小写），避免句子中间的同名词被意外替换。
public enum Snippets {
    public static func expansion(for text: String, in snippets: [String: String]) -> String? {
        let spoken = normalize(text)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { normalize($0.key) == spoken && !$0.value.isEmpty }?.value
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }.map(Character.init))
    }
}
