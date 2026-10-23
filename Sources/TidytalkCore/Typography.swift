import Foundation

/// 中英文混排规范，在本地确定性地处理，不依赖 AI 整理：
///
/// - 全角英文字母和数字转为半角（Ａｐｐ１ → App1）；
/// - 中文后面的半角标点转为全角（"好的," → "好的，"）；
/// - 全角标点两侧不留空格；
/// - 中文与英文、数字之间加一个空格（"用API调5次" → "用 API 调 5 次"）。
public enum Typography {
    public static func format(_ text: String, convertPunctuation: Bool = true) -> String {
        var chars = Array(text).map(halfWidthAlphanumeric)
        if convertPunctuation { chars = fullWidthPunctuation(chars) }
        chars = trimSpacesAroundFullWidthPunctuation(chars)
        chars = spaceBetweenCJKAndLatin(chars)
        return String(chars)
    }

    // MARK: - 字符分类

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF,
             0x3040...0x30FF: // 平假名、片假名
            return true
        default:
            return false
        }
    }

    /// 是否含有平假名或片假名，也就是日文。
    public static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) && $0.value != 0x30FB }
    }

    static func isLatinOrDigit(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    static let fullWidthPunctuationSet: Set<Character> = Set("，。？！：；、（）《》〈〉「」『』“”‘’【】…—")

    private static let punctuationMap: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
    ]

    // MARK: - 规则

    /// Ａ-Ｚ、ａ-ｚ、０-９ → 半角
    private static func halfWidthAlphanumeric(_ c: Character) -> Character {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return c }
        switch s.value {
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return Character(Unicode.Scalar(s.value - 0xFEE0)!)
        default:
            return c
        }
    }

    /// 紧跟在中文后面的半角标点改为全角；数字中的小数点、网址、省略号等不受影响。
    private static func fullWidthPunctuation(_ chars: [Character]) -> [Character] {
        var result = chars
        for i in chars.indices {
            guard let full = punctuationMap[chars[i]] else { continue }
            // 前一个非空格字符必须是中文
            var j = i - 1
            while j >= 0, chars[j] == " " { j -= 1 }
            guard j >= 0, isCJK(chars[j]) else { continue }
            // 连续的点（省略号）、后面紧跟英文或数字（如 "中文.txt"）时不转换
            if chars[i] == ".", (i + 1 < chars.count && chars[i + 1] == ".") || (i > 0 && chars[i - 1] == ".") {
                continue
            }
            if i + 1 < chars.count, isLatinOrDigit(chars[i + 1]) { continue }
            result[i] = full
        }
        return result
    }

    private static func trimSpacesAroundFullWidthPunctuation(_ chars: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            if c == " " {
                let prev = result.last
                let next = chars[(i + 1)...].first { $0 != " " }
                if let prev, fullWidthPunctuationSet.contains(prev) { continue }
                if let next, fullWidthPunctuationSet.contains(next) { continue }
            }
            result.append(c)
        }
        return result
    }

    private static func spaceBetweenCJKAndLatin(_ chars: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(chars.count + 8)
        for c in chars {
            if let prev = result.last {
                let needsSpace = (isCJK(prev) && isLatinOrDigit(c))
                    || ((isLatinOrDigit(prev) || prev == "%") && isCJK(c))
                if needsSpace { result.append(" ") }
            }
            result.append(c)
        }
        return result
    }
}
