import Foundation

/// 从应用外部控制 Tidytalk 的网址，方便在 Raycast、快捷指令、Karabiner 等工具里绑定：
///
/// - `tidytalk://toggle`：开始说话输入（像双击快捷键一样不用按住），再打开一次结束
/// - `tidytalk://start`、`tidytalk://stop`：只开始、只结束
/// - `tidytalk://cancel`：取消这次录音
/// - `tidytalk://captions`：开关实时字幕；`tidytalk://captions/start`、`tidytalk://captions/stop`
public enum ExternalCommand: Equatable, Sendable {
    case toggle
    case start
    case stop
    case cancel
    case captions(Captions)

    public enum Captions: Equatable, Sendable {
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
            switch words.dropFirst().first {
            case nil, "toggle": self = .captions(.toggle)
            case "start": self = .captions(.start)
            case "stop": self = .captions(.stop)
            default: return nil
            }
        default: return nil
        }
    }
}
