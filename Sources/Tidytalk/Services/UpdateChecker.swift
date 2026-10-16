import AppKit
import TidytalkCore

/// 检查更新：从构建时写入 Info.plist 的地址（`TidytalkUpdateURL`）读取一个 JSON：
///
/// ```json
/// { "version": "0.2.0", "url": "https://example.com/Tidytalk-0.2.0.dmg", "notes": "更新内容" }
/// ```
///
/// 发现新版本时提示用户，并打开下载地址。没有配置地址时整个功能隐藏。
@MainActor
enum UpdateChecker {
    struct Release: Decodable {
        let version: String
        let url: URL
        let notes: String?
    }

    static var feedURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TidytalkUpdateURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return URL(string: raw)
    }

    static var isConfigured: Bool { feedURL != nil }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let lastCheckKey = "lastUpdateCheck"

    /// 启动时自动检查，一天最多一次，没有新版本时不打扰。
    static func checkInBackgroundIfNeeded(enabled: Bool) {
        guard enabled, isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    /// - Parameter userInitiated: 用户手动检查时，没有新版本或出错也会提示。
    static func check(userInitiated: Bool) async {
        guard let feedURL else { return }
        do {
            let release = try await fetchLatest(from: feedURL)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            if AppVersion.isNewer(release.version, than: currentVersion) {
                present(release)
            } else if userInitiated {
                alert(String(localized: "已是最新版本"), String(localized: "当前版本 \(currentVersion)。"))
            }
        } catch {
            if userInitiated { alert(String(localized: "检查更新失败"), error.localizedDescription) }
        }
    }

    nonisolated static func fetchLatest(from url: URL) async throws -> Release {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private static func present(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "发现新版本 \(release.version)")
        alert.informativeText = (release.notes.map { $0 + "\n\n" } ?? "") + String(localized: "当前版本 \(currentVersion)。")
        alert.addButton(withTitle: String(localized: "下载"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.url)
        }
    }

    private static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
