import Foundation

/// 界面的深浅色：跟随系统，或者固定用浅色、深色（设置 › 通用 › 外观）。
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }
}
