import Foundation

/// 版本号比较（"0.10.1" 比 "0.9.3" 新）。
public enum AppVersion {
    /// 预发布版本（"0.2.2-beta.1"）比同号的正式版旧。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let (a, aPre) = parts(candidate), (b, bPre) = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        switch (aPre, bPre) {
        case (nil, .some): return true
        case let (.some(x), .some(y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    private static func parts(_ version: String) -> ([Int], String?) {
        let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let pieces = trimmed.split(separator: "-", maxSplits: 1)
        let core = pieces.first.map(String.init) ?? ""
        let pre = pieces.count > 1 ? String(pieces[1]) : nil
        return (core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, pre)
    }
}
