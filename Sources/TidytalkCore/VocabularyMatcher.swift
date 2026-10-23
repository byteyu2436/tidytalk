import Foundation

/// 在本机把识别结果里"差一点"的词纠正成词库里的写法，不依赖 AI，关闭整理时也生效。
///
/// 为了不误改正常的词，只处理把握比较大的情况：
/// - 英文：大小写或空格不同但字母完全一样（"github" → "GitHub"、"chat gpt" → "ChatGPT"）；
///   较长的词（7 个字母以上）允许拼错 1 个字母，10 个字母以上允许 2 个（"Kubernetis" → "Kubernetes"）。
///   网址、邮箱、文件路径里的词不动。
/// - 中文：3 个字以上的词，读音（不计声调）完全相同、并且至少有一个字相同的同音字（"张三峰" → "张三丰"）。
///   两个字的词同音的太多，不处理。
///
/// 真实存在的英文单词（由应用通过 `dictionaryWordCheck` 提供拼写检查）不做模糊匹配，避免"discard"被改成"Discord"；
/// 只差大小写的普通单词（"outlook"）、拆开的普通单词（"we chat"）只在挨着中文时才改——这种情况基本只出现在中英混说里。
public enum VocabularyMatcher {
    /// 判断是不是真实存在的英文单词，由应用在启动时设置（用系统拼写检查）。为 nil 时都当作不是。
    public static var dictionaryWordCheck: (@Sendable (String) -> Bool)? {
        get { checkLock.withLock { check } }
        set { checkLock.withLock { check = newValue } }
    }
    private static let checkLock = NSLock()
    nonisolated(unsafe) private static var check: (@Sendable (String) -> Bool)?

    private static func isDictionaryWords(_ text: String, check: ((String) -> Bool)?) -> Bool {
        guard let check else { return false }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "-" })
        return !words.isEmpty && words.allSatisfy { check(String($0)) }
    }

    /// - Parameter isWord: 判断真实英文单词的函数，默认用 `dictionaryWordCheck`（测试时可以单独传入）。
    public static func correct(_ text: String, terms: [String], isWord: ((String) -> Bool)? = nil) -> String {
        let isWord = isWord ?? dictionaryWordCheck
        let terms = Vocabulary.normalize(terms)
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let latin = terms.compactMap(LatinTerm.init)
        let han = terms.filter { $0.count >= 3 && $0.allSatisfy(isHan) }
        var result = text
        if !latin.isEmpty { result = correctLatin(result, terms: latin, isWord: isWord) }
        if !han.isEmpty { result = correctHan(result, terms: han) }
        return result
    }

    // MARK: - 英文

    struct LatinTerm {
        let text: String
        /// 只保留字母和数字的小写形式，用来比较。
        let key: [Character]
        /// 词库里写成几个词（"Claude Code" 是 2 个）。
        let words: Int

        init?(_ text: String) {
            guard text.unicodeScalars.allSatisfy({ $0.isASCII }),
                  text.contains(where: { $0.isLetter })
            else { return nil }
            let key = VocabularyMatcher.key(text)
            guard key.count >= 3 else { return nil }
            self.text = text
            self.key = key
            self.words = text.split(whereSeparator: { $0 == " " || $0 == "-" }).count
        }
    }

    static func key<S: Sequence>(_ s: S) -> [Character] where S.Element == Character {
        s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { Character($0.lowercased()) }
    }

    private struct Token {
        let range: Range<Int>
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 网址、邮箱、路径、代码标识符里的词：前后紧挨着这些符号。
    private static let embedding: Set<Character> = ["@", "/", "\\", "_", ":", "#", "=", "&", "?"]

    private static func correctLatin(_ text: String, terms: [LatinTerm], isWord: ((String) -> Bool)?) -> String {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else { i += 1; continue }
            let start = i
            while i < chars.count, isWordChar(chars[i]) { i += 1 }
            tokens.append(Token(range: start..<i))
        }
        guard !tokens.isEmpty else { return text }

        func embedded(_ range: Range<Int>) -> Bool {
            let before = range.lowerBound > 0 ? chars[range.lowerBound - 1] : nil
            let after = range.upperBound < chars.count ? chars[range.upperBound] : nil
            if let before, embedding.contains(before) || before == "." { return true }
            if let after, embedding.contains(after) { return true }
            // "github.com" 里的点后面还连着字母；句末的点不算
            if after == ".", range.upperBound + 1 < chars.count, isWordChar(chars[range.upperBound + 1]) { return true }
            return false
        }

        /// 前后最近的非空格字符是不是汉字：中英混说的上下文。
        func nextToHan(_ range: Range<Int>) -> Bool {
            var i = range.lowerBound - 1
            while i >= 0, chars[i] == " " { i -= 1 }
            if i >= 0, isHan(chars[i]) { return true }
            var j = range.upperBound
            while j < chars.count, chars[j] == " " { j += 1 }
            return j < chars.count && isHan(chars[j])
        }

        /// 相邻两个词之间只有空格或一个连字符，才能当成一个词组比较。
        func joinable(_ a: Token, _ b: Token) -> Bool {
            let gap = chars[a.range.upperBound..<b.range.lowerBound]
            return !gap.isEmpty && gap.count <= 2 && gap.allSatisfy { $0 == " " || $0 == "-" }
        }

        var replacements: [(Range<Int>, String)] = []
        var t = 0
        while t < tokens.count {
            var matched = false
            for n in stride(from: min(3, tokens.count - t), through: 1, by: -1) {
                let group = tokens[t..<(t + n)]
                guard zip(group, group.dropFirst()).allSatisfy({ joinable($0, $1) }) else { continue }
                let span = group.first!.range.lowerBound..<group.last!.range.upperBound
                guard !embedded(span) else { continue }
                let candidate = String(chars[span])
                let candidateKey = key(candidate)
                guard let (term, exact) = bestTerm(for: candidateKey, words: n, in: terms) else { continue }
                let mixed = nextToHan(span)
                let ordinary = isDictionaryWords(candidate, check: isWord)
                // 把几个普通单词拼成一个词（"we chat" → "WeChat"）、只改普通单词的大小写（"outlook" → "Outlook"）、
                // 或者模糊匹配普通单词，都只在中英混说里做
                // 词库里本来就写成几个词（"Claude Code"）时，按原样分词出现不算拼接
                let allowed = exact
                    ? (!ordinary || mixed || (n > 1 && term.words == n))
                    : (!ordinary || (mixed && term.words == n))
                guard allowed, n == 1 || term.words == n || mixed else { continue }
                if term.text != candidate { replacements.append((span, term.text)) }
                t += n
                matched = true
                break
            }
            if !matched { t += 1 }
        }
        return apply(replacements, to: chars)
    }

    /// 找最接近的词：完全相同（只差大小写、空格）时 exact 为 true。
    private static func bestTerm(for candidate: [Character], words: Int, in terms: [LatinTerm]) -> (LatinTerm, exact: Bool)? {
        if let exact = terms.first(where: { $0.key == candidate }) { return (exact, true) }
        var best: (LatinTerm, Int)?
        for term in terms {
            let length = term.key.count
            // 单个词要足够长才模糊匹配，避免"nation"被改成"Notion"这类误伤
            let allowed = length >= 10 ? 2 : (length >= 7 ? 1 : 0)
            guard allowed > 0, words > 1 || length >= 7,
                  abs(candidate.count - length) <= allowed,
                  candidate.first == term.key.first,
                  // 复数、加后缀的形式不算拼错
                  !(candidate.starts(with: term.key) && candidate.count > length)
            else { continue }
            let distance = levenshtein(candidate, term.key)
            if distance <= allowed, best.map({ distance < $0.1 }) ?? true { best = (term, distance) }
        }
        return best.map { ($0.0, false) }
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - 中文

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }

    // NSCache 自身是线程安全的
    nonisolated(unsafe) private static let pinyinCache = NSCache<NSString, NSString>()

    /// 单个汉字的拼音，不带声调。
    static func pinyin(_ c: Character) -> String {
        let key = String(c) as NSString
        if let cached = pinyinCache.object(forKey: key) { return cached as String }
        let s = NSMutableString(string: String(c)) as CFMutableString
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (s as String).lowercased()
        pinyinCache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func correctHan(_ text: String, terms: [String]) -> String {
        let chars = Array(text)
        var sounds: [String?] = chars.map { isHan($0) ? pinyin($0) : nil }
        let sortedTerms = terms.sorted { $0.count > $1.count }.map { (text: $0, chars: Array($0), sound: Array($0).map(pinyin)) }
        var replacements: [(Range<Int>, String)] = []
        var i = 0
        while i < chars.count {
            var advanced = false
            for term in sortedTerms where i + term.chars.count <= chars.count {
                let range = i..<(i + term.chars.count)
                guard sounds[range].allSatisfy({ $0 != nil }) else { continue }
                if Array(chars[range]) == term.chars {
                    i = range.upperBound
                    advanced = true
                    break
                }
                // 读音完全相同，并且至少有一个字相同（真实的识别错误通常会保留一部分字，
                // 完全不同的字只是碰巧同音，比如"离假期"和"李佳琦"）
                if zip(sounds[range], term.sound).allSatisfy({ $0 == $1 }),
                   zip(chars[range], term.chars).contains(where: { $0 == $1 }) {
                    replacements.append((range, term.text))
                    for k in range { sounds[k] = nil }
                    i = range.upperBound
                    advanced = true
                    break
                }
            }
            if !advanced { i += 1 }
        }
        return apply(replacements, to: chars)
    }

    private static func apply(_ replacements: [(Range<Int>, String)], to chars: [Character]) -> String {
        guard !replacements.isEmpty else { return String(chars) }
        var result = ""
        var cursor = 0
        for (range, text) in replacements.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) where range.lowerBound >= cursor {
            result += String(chars[cursor..<range.lowerBound])
            result += text
            cursor = range.upperBound
        }
        result += String(chars[cursor...])
        return result
    }
}
