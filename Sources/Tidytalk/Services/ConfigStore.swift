import AppKit
import Observation
import TidytalkCore

/// 读写用户目录下的隐藏配置文件 `~/.tidytalk.json`。
///
/// 文件可以直接用文本编辑器修改；应用在打开设置、每次整理前都会重新读取。
@MainActor
@Observable
final class ConfigStore {
    nonisolated static var fileURL: URL {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        // 开发用：`--config <文件>` 改用另一份配置，截图时不碰真实设置
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--config"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tidytalk.json")
    }

    private(set) var config = AppConfig()
    /// 文件存在但无法解析时的错误说明；此时使用默认配置。
    private(set) var loadError: String?

    init() {
        reload()
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            // 首次启动写一份默认配置，方便用户找到并手动编辑
            save(config)
        }
    }

    func reload() {
        let loaded: AppConfig
        let message: String?
        do {
            loaded = try Self.read()
            message = nil
        } catch {
            loaded = AppConfig()
            message = String(localized: "配置文件 ~/.tidytalk.json 格式错误：\(error.localizedDescription)")
        }
        // 只在变化时赋值，避免无谓地刷新界面
        if config != loaded { config = loaded }
        if loadError != message { loadError = message }
    }

    /// 读取失败（文件不存在）时返回默认配置。
    nonisolated static func read() throws -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        return try AppConfig.decode(data)
    }

    @discardableResult
    func save(_ newConfig: AppConfig) -> Bool {
        do {
            let existing = loadError == nil ? try? Data(contentsOf: Self.fileURL) : nil
            let data = try newConfig.encode(merging: existing)
            try data.write(to: Self.fileURL, options: .atomic)
            // 文件里有 API Key，只允许当前用户读写
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
            config = newConfig
            loadError = nil
            return true
        } catch {
            loadError = String(localized: "无法写入配置文件：\(error.localizedDescription)")
            return false
        }
    }

    /// 修改当前配置的一部分并保存。
    @discardableResult
    func update(_ change: (inout AppConfig) -> Void) -> Bool {
        var newConfig = config
        change(&newConfig)
        guard newConfig != config else { return true }
        return save(newConfig)
    }

    /// 用默认的文本编辑器打开配置文件。
    func openInEditor() {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { save(config) }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
