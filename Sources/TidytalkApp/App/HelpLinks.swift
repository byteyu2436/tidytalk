import AppKit

/// 官网上的使用指南和隐私说明：按界面语言打开中文或英文页。
enum HelpLinks {
    static let site = "https://tidytalk.zayen.dev"

    private static var chinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
    }

    static var guide: URL { URL(string: site + (chinese ? "/zh/docs/" : "/docs/"))! }
    static var privacy: URL { URL(string: site + (chinese ? "/zh/privacy/" : "/privacy/"))! }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
