import Foundation

/// 用户补充的整理规则，例如"金额一律用阿拉伯数字""称呼统一用'您'""产品名写作 Tidytalk"。
public enum CustomRules {
    /// 最多带进提示词的条数和每条的长度，避免提示过长。
    public static let limit = 20
    public static let maxLength = 200

    /// 去掉空行、重复项，截断过长的条目。
    public static func normalize(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// 追加到系统提示里的说明；没有规则时为 nil。
    static func promptSection(_ rules: [String]) -> String? {
        let rules = normalize(rules)
        guard !rules.isEmpty else { return nil }
        let list = rules.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        用户的个人要求（在不违背上面规则的前提下遵守；只影响写法，不要因此增加原文没有的内容）：
        \(list)
        """
    }
}
