import AppKit
import TidytalkCore

extension AppAppearance {
    /// 换外观：整个应用（主窗口、指示器、字幕条）一起换，马上生效。
    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 界面语言：跟随系统，或者固定用简体中文、English（设置 › 通用 › 语言）。
///
/// 存在 Tidytalk 自己的 `AppleLanguages` 里，和“系统设置 › 通用 › 语言与地区 › 应用程序”里给单个应用选语言是同一个设置。
/// macOS 只在启动时读它，所以改完要重新打开 Tidytalk 才生效。
enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    /// 选项里的名字：语言名用它自己的文字写，跟随系统时括号里写现在是哪种。
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统（\(Self.name(Self.systemCode))）")
        case .chinese, .english: Self.name(rawValue)
        }
    }

    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 截图用：假装选了某种语言，不改真的设置
    nonisolated(unsafe) static var simulated: AppLanguage?
    #endif

    static var selected: AppLanguage {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        if let simulated { return simulated }
        #endif
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let code = (domain?["AppleLanguages"] as? [String])?.first
        return Self.allCases.first { $0 != .system && code?.hasPrefix($0.rawValue) == true } ?? .system
    }

    static func select(_ language: AppLanguage) {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        if simulated != nil {
            simulated = language
            return
        }
        #endif
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// 现在界面用的语言（启动时定下的）
    static var runningCode: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// 跟随系统时会用哪种：按 macOS 的首选语言，在 Tidytalk 有的语言里挑。
    static var systemCode: String {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        return Bundle.preferredLocalizations(from: available, forPreferences: global ?? Locale.preferredLanguages)
            .first ?? "en"
    }

    /// 选了这种语言、重新打开以后会用哪种
    var code: String { self == .system ? Self.systemCode : rawValue }

    /// 选的语言和现在显示的不一样：要重新打开才生效
    static var needsRelaunch: Bool { selected.code != runningCode }

    static func name(_ code: String) -> String {
        code.hasPrefix("zh") ? "简体中文" : "English"
    }

    /// 重新打开 Tidytalk：等这个进程退出后再打开，免得 open 只是把还没退出的这个调到前面。
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? task.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
