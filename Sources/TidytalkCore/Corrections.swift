import Foundation

/// 用户在粘贴后手动改掉的一个词，例如"克劳德"改成"Claude"。
public struct WordCorrection: Hashable, Sendable, Identifiable {
    public let from: String
    public let to: String
    public var id: String { from + "\u{1F}" + to }

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 自动学词：对比粘贴出去的文字和用户改过之后的文字，找出被改掉的词。
///
/// 只找"把某个词换成另一个词"的改动；整句重写、只加删内容、只改标点都不算，避免把正常修改当成识别错误。
public enum Corrections {
    /// 一处改动最多这么长，再长就不像是认错了一个词。
    static let maxLength = 20
    /// 改动的字数超过这个比例，当作重写而不是纠错。
    static let maxChangedRatio = 0.5

    public static func find(original: String, edited: String) -> [WordCorrection] {
        let a = tokens(original), b = tokens(edited)
        guard a != b, !a.isEmpty else { return [] }
        let hunks = diff(a, b)
        // 两边改动的字数（不算空白和标点）占两边总字数的比例
        let changed = hunks.reduce(0) { total, hunk in
            total + a[hunk.removed].filter { !$0.isSeparator }.count + b[hunk.inserted].filter { !$0.isSeparator }.count
        }
        let meaningful = a.filter { !$0.isSeparator }.count + b.filter { !$0.isSeparator }.count
        guard Double(changed) <= Double(max(meaningful, 1)) * maxChangedRatio, hunks.count <= 5 else { return [] }

        var result: [WordCorrection] = []
        for hunk in hunks {
            guard let correction = correction(for: hunk, in: a, b) else { continue }
            if !result.contains(correction) { result.append(correction) }
        }
        return result
    }

    /// 在用户编辑后的整段内容里找到原来粘贴的那段：用粘贴位置前后的文字定位。找不到时返回 nil。
    public static func region(in value: String, before prefix: String, after suffix: String) -> String? {
        let start: String.Index
        if prefix.isEmpty {
            start = value.startIndex
        } else if let range = value.range(of: prefix, options: .backwards) {
            start = range.upperBound
        } else {
            return nil
        }
        let end: String.Index
        if suffix.isEmpty {
            end = value.endIndex
        } else if let range = value.range(of: suffix, range: start..<value.endIndex) {
            end = range.lowerBound
        } else {
            return nil
        }
        return String(value[start..<end])
    }

    // MARK: - 分词和对比

    /// 拉丁字母和数字连成一个词，汉字、假名、谚文每个字单独算，标点和空白各自单独算。
    struct Token: Equatable {
        let text: String
        let isCJK: Bool
        var isSeparator: Bool {
            text.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
                    || CharacterSet.symbols.contains($0)
            }
        }
    }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var word = ""
        func flush() {
            if !word.isEmpty { result.append(Token(text: word, isCJK: false)) }
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" {
                if isCJK(character) {
                    flush()
                    result.append(Token(text: String(character), isCJK: true))
                } else {
                    word.append(character)
                }
            } else {
                flush()
                result.append(Token(text: String(character), isCJK: false))
            }
        }
        flush()
        return result
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
    }

    struct Hunk {
        /// 原文和修改后文字里被替换的位置。
        let removed: Range<Int>
        let inserted: Range<Int>
    }

    /// 最长公共子序列，找出两边对不上的片段。
    static func diff(_ a: [Token], _ b: [Token]) -> [Hunk] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var start: (Int, Int)?
        func close() {
            if let (si, sj) = start, si < i || sj < j { hunks.append(Hunk(removed: si..<i, inserted: sj..<j)) }
            start = nil
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close()
                i += 1
                j += 1
            } else {
                if start == nil { start = (i, j) }
                if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        close()
        return hunks
    }

    /// 把一处替换整理成"错误写法 → 正确写法"；不像纠错的改动返回 nil。
    static func correction(for hunk: Hunk, in a: [Token], _ b: [Token]) -> WordCorrection? {
        var removed = hunk.removed, inserted = hunk.inserted
        // 去掉两头的空白和标点
        while let first = removed.first, a[first].isSeparator { removed = removed.dropFirst() }
        while let last = removed.last, a[last].isSeparator { removed = removed.dropLast() }
        while let first = inserted.first, b[first].isSeparator { inserted = inserted.dropFirst() }
        while let last = inserted.last, b[last].isSeparator { inserted = inserted.dropLast() }
        guard !removed.isEmpty, !inserted.isEmpty else { return nil }

        // 只改了一个汉字时（"用力"改成"用例"），带上旁边没改的字，免得以后把所有"力"都替换掉
        var lower = removed.lowerBound, upper = removed.upperBound
        var insertedLower = inserted.lowerBound, insertedUpper = inserted.upperBound
        func text(_ range: Range<Int>, _ tokens: [Token]) -> String { tokens[range].map(\.text).joined() }
        while text(lower..<upper, a).count < 2, a[lower..<upper].allSatisfy(\.isCJK) {
            if lower > 0, a[lower - 1].isCJK, insertedLower > 0, b[insertedLower - 1] == a[lower - 1] {
                lower -= 1
                insertedLower -= 1
            } else if upper < a.count, a[upper].isCJK, insertedUpper < b.count, b[insertedUpper] == a[upper] {
                upper += 1
                insertedUpper += 1
            } else {
                break
            }
        }

        let from = text(lower..<upper, a), to = text(insertedLower..<insertedUpper, b)
        guard from != to, from.count <= maxLength, to.count <= maxLength + 10,
              from.trimmingCharacters(in: .whitespaces).count >= 2 || from.contains(where: { !isCJK($0) })
        else { return nil }
        return WordCorrection(from: from, to: to)
    }
}
