import Foundation

/// 从应用外部控制 Tidytalk 的网址，方便在 Raycast、快捷指令、Karabiner 等工具里绑定：
///
/// - `tidytalk://toggle`：开始说话输入（像双击快捷键一样不用按住），再打开一次结束
/// - `tidytalk://start`、`tidytalk://stop`：只开始、只结束
/// - `tidytalk://cancel`：取消这次录音
/// - `tidytalk://captions`：开关实时字幕；`tidytalk://captions/start`、`tidytalk://captions/stop`
/// - `tidytalk://meeting`：开始或结束会议记录；`tidytalk://meeting/start`、`tidytalk://meeting/stop`
public enum ExternalCommand: Equatable, Sendable {
    case toggle
    case start
    case stop
    case cancel
    case captions(Switch)
    case meeting(Switch)

    /// 开关类命令：切换、只打开、只关闭。
    public enum Switch: Equatable, Sendable {
        case toggle, start, stop
    }

    public static let scheme = "tidytalk"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // tidytalk://toggle 的 toggle 是 host；也接受 tidytalk:toggle 这种写法
        let parts = ([url.host() ?? ""] + url.pathComponents)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != "/" }
        let words = parts.isEmpty
            ? url.absoluteString.dropFirst(Self.scheme.count + 1).split(separator: "/").map { $0.lowercased() }
            : parts
        switch words.first {
        case "toggle": self = .toggle
        case "start": self = .start
        case "stop": self = .stop
        case "cancel": self = .cancel
        case "captions":
            guard let action = Self.switchAction(words.dropFirst().first) else { return nil }
            self = .captions(action)
        case "meeting":
            guard let action = Self.switchAction(words.dropFirst().first) else { return nil }
            self = .meeting(action)
        default: return nil
        }
    }

    private static func switchAction(_ word: String?) -> Switch? {
        switch word {
        case nil, "toggle": .toggle
        case "start": .start
        case "stop": .stop
        default: nil
        }
    }
}
