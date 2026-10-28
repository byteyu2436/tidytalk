import AppKit

/// 官网上的使用指南、隐私说明和更新日志（按界面语言打开中文或英文页），以及 GitHub 上的源代码。
enum HelpLinks {
    static let site = "https://tidytalk.zayen.dev"

    private static var chinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
    }

    static var guide: URL { URL(string: site + (chinese ? "/zh/docs/" : "/docs/"))! }
    static var privacy: URL { URL(string: site + (chinese ? "/zh/privacy/" : "/privacy/"))! }
    static var changelog: URL { URL(string: site + (chinese ? "/zh/changelog/" : "/changelog/"))! }
    static let source = URL(string: "https://github.com/byteyu2436/tidytalk")!
    static let issues = URL(string: "https://github.com/byteyu2436/tidytalk/issues")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
