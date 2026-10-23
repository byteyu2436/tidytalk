import AppKit
import Observation
import SwiftUI
import TidytalkCore

/// 读写用户目录下的隐藏配置文件 `~/.tidytalk.json`。
///
/// 文件可以直接用文本编辑器修改；应用在打开设置、每次整理前都会重新读取。
@MainActor
@Observable
final class ConfigStore {
    /// 默认的配置文件位置。
    nonisolated static var defaultFileURL: URL {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        // 开发用：`--config <文件>` 改用另一份配置，截图时不碰真实设置
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--config"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tidytalk.json")
    }

    /// 这份配置读写的文件。测试时传入临时文件。
    let fileURL: URL
    /// 存 API Key 的地方；为 nil 时 Key 和其他设置一起写在文件里。
    let keychain: (any APIKeyStore)?

    private(set) var config = AppConfig()
    /// 文件存在但无法读取或解析时的错误说明；此时使用默认配置，并且拒绝保存，免得覆盖用户的文件。
    private(set) var loadError: String?
    /// 文件存在但读不了或格式错误。和写入失败分开：写入失败后下一次还可以再试。
    private var fileIsBroken = false

    /// API Key 默认存在钥匙串里。开发时用 `--config` 指定的临时配置不读写钥匙串，截图里不会出现真实的 Key。
    nonisolated static var defaultKeychain: (any APIKeyStore)? {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        return CommandLine.arguments.contains("--config") ? nil : KeychainStore.shared
        #else
        return KeychainStore.shared
        #endif
    }

    init(fileURL: URL = ConfigStore.defaultFileURL, keychain: (any APIKeyStore)? = ConfigStore.defaultKeychain) {
        self.fileURL = fileURL
        self.keychain = keychain
        reload()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // 首次启动写一份默认配置，方便用户找到并手动编辑
            save(config)
        }
    }

    /// 配置文件存在但读不了（和格式错误分开提示）。
    struct Unreadable: Error {
        let underlying: Error
    }

    /// 第一次从钥匙串读取 API Key 的后台任务。钥匙串可能等待用户授权，不能在主线程上等。
    private var keychainLoad: Task<Void, Never>?
    /// 上一次读钥匙串失败的时间：失败后过一阵再试，免得每次说话都弹授权窗。
    private var keychainFailedAt: Date?
    private static let keychainRetryInterval: TimeInterval = 300

    func reload() {
        let loaded: AppConfig
        let message: String?
        do {
            loaded = try Self.read(from: fileURL, keychain: keychain, waitForKeychain: false)
            message = nil
        } catch let error as Unreadable {
            // 文件存在但读不了（例如没有权限），同样不能覆盖
            loaded = AppConfig()
            message = String(localized: "无法读取配置文件 ~/.tidytalk.json：\(error.underlying.localizedDescription)")
        } catch {
            loaded = AppConfig()
            message = String(localized: "配置文件 ~/.tidytalk.json 格式错误：\(error.localizedDescription)")
        }
        loadKeychainIfNeeded(fileHasKey: !loaded.ai.apiKey.isEmpty)
        // 只在变化时赋值，避免无谓地刷新界面
        if config != loaded { config = loaded }
        if loadError != message { loadError = message }
        fileIsBroken = message != nil
    }

    /// 钥匙串里的 Key 还没读过时，在后台读一次，读完重新加载配置。
    private func loadKeychainIfNeeded(fileHasKey: Bool) {
        guard let keychain, !fileHasKey, keychainLoad == nil, keychain.cachedAPIKey == .unknown else { return }
        if let keychainFailedAt, Date().timeIntervalSince(keychainFailedAt) < Self.keychainRetryInterval { return }
        keychainLoad = Task {
            let found = await Task.detached { keychain.readAPIKey() != nil }.value
            keychainLoad = nil
            keychainFailedAt = keychain.cachedAPIKey == .unknown ? Date() : nil
            if found { reload() }
        }
    }

    /// 等第一次读取钥匙串完成。整理文字前调用，刚启动就说话时也能用上 API Key。
    func keychainReady() async {
        await keychainLoad?.value
    }

    /// 文件不存在时返回默认配置；文件存在但读不了（没有权限）或格式错误时抛出错误。
    /// 文件里没有写 API Key 时，从钥匙串里取；`waitForKeychain` 为 false 时只用已经读到的缓存，不访问钥匙串。
    nonisolated static func read(from url: URL = defaultFileURL, keychain: (any APIKeyStore)? = defaultKeychain,
                                 waitForKeychain: Bool = true) throws -> AppConfig {
        var config: AppConfig
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw Unreadable(underlying: error) }
            config = try AppConfig.decode(data)
        } else {
            config = AppConfig()
        }
        if let keychain, config.ai.apiKey.isEmpty {
            if waitForKeychain, let key = keychain.readAPIKey() {
                config.ai.apiKey = key
            } else if case .key(let key) = keychain.cachedAPIKey {
                config.ai.apiKey = key
            }
        }
        return config
    }

    @discardableResult
    func save(_ newConfig: AppConfig) -> Bool {
        // 文件格式错误时不保存：保存会用默认值覆盖用户的整份配置（API Key、词库、替换表……）
        guard !fileIsBroken else { return false }
        do {
            let existing = try? Data(contentsOf: fileURL)
            var stored = newConfig
            // API Key 放进钥匙串，文件里不再写明文；钥匙串不可用时仍然写在文件里，不至于丢失
            if let keychain {
                let key = newConfig.ai.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    // 只有用户清空了一个确实存在的 Key 才删除；钥匙串读取失败时 Key 看起来也是空的，不能删
                    if keychain.hasStoredKey { keychain.deleteAPIKey() }
                } else if keychain.saveAPIKey(key) {
                    stored.ai.apiKey = ""
                }
            }
            try Self.writePrivately(try stored.encode(merging: existing), to: fileURL)
            config = newConfig
            loadError = nil
            return true
        } catch {
            loadError = String(localized: "无法写入配置文件：\(error.localizedDescription)")
            return false
        }
    }

    /// 先写一个权限为 0600 的临时文件再原子替换：文件从创建起就只有当前用户能读，没有可被别人读到的窗口。
    nonisolated static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        // 用 open 直接以 0600 创建（FileManager.createFile 是先写入再改权限）
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 修改当前配置的一部分并保存。先重新读取文件，免得用内存里的旧值覆盖用户刚在编辑器里改的内容。
    @discardableResult
    func update(_ change: (inout AppConfig) -> Void) -> Bool {
        reload()
        guard !fileIsBroken else { return false }
        var newConfig = config
        change(&newConfig)
        guard newConfig != config else { return true }
        return save(newConfig)
    }

    /// 设置界面用的绑定：读当前配置，改动时重新读取文件后保存（见 `update`），不会覆盖用户在编辑器里的修改。
    func binding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// 用默认的文本编辑器打开配置文件。
    func openInEditor() {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) { save(config) }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
