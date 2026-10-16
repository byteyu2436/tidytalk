import Foundation

/// 整理强度。
public enum CleanupLevel: String, CaseIterable, Sendable {
    /// 只补标点、删纯语气的填充词，其余原话保留。
    case light
    case standard
    /// 在标准基础上进一步精简啰嗦和重复的表达。
    case thorough

    public var title: String {
        switch self {
        case .light: String(localized: "轻度")
        case .standard: String(localized: "标准")
        case .thorough: String(localized: "深度")
        }
    }

    public var summary: String {
        switch self {
        case .light: String(localized: "只加标点、删语气词。")
        case .standard: String(localized: "删除口头禅和口误，补全标点。")
        case .thorough: String(localized: "进一步精简重复、啰嗦的表达，不改原意。")
        }
    }

    /// 追加到系统提示里的说明；标准强度不追加。
    var instruction: String? {
        switch self {
        case .standard:
            nil
        case .light:
            """
            整理强度：轻度。只补全标点、断句，删除"嗯、呃、啊"这类纯语气的填充词，修正明显的识别错误；\
            其余字词一律保留原样，包括口头禅、重复的说法和改口前的内容。
            """
        case .thorough:
            """
            整理强度：深度。在上述规则基础上，进一步精简啰嗦、重复和绕弯的表达，理顺语序，合并意思相同的句子，\
            让文字更简洁；但不得改变原意，不得增加原文没有的信息。
            """
        }
    }

    /// 校验时允许删减的下限：深度整理删得更多，放宽到原文的两成。
    var minimumKeptRatio: Double {
        self == .thorough ? 0.2 : 0.3
    }
}
