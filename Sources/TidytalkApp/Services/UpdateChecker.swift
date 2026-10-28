import AppKit
import TidytalkCore

/// 检查更新：从构建时写入 Info.plist 的地址（`TidytalkUpdateURL`）读取最新版本，支持两种格式：
///
/// - GitHub Releases 接口，例如 `https://api.github.com/repos/<owner>/<repo>/releases/latest`，
///   版本号取 `tag_name`（去掉开头的 v），下载地址取发布页 `html_url`；
/// - 自建的 JSON：`{ "version": "0.2.0", "url": "https://example.com/Tidytalk-0.2.0.dmg", "notes": "更新内容" }`。
///
/// 发现新版本时提示用户，并打开下载地址。没有配置地址时整个功能隐藏。
@MainActor
enum UpdateChecker {
    struct Release: Decodable {
        let version: String
        let url: URL
        let notes: String?
    }

    /// GitHub Releases 接口返回的字段。
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
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
    private static let latestKey = "latestVersionSeen"

    /// 上次检查到的最新版本；没检查过时为 nil（“关于”里显示是不是最新版本）。
    static var latestKnownVersion: String? { UserDefaults.standard.string(forKey: latestKey) }

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
            UserDefaults.standard.set(release?.version ?? currentVersion, forKey: latestKey)

            if let release, AppVersion.isNewer(release.version, than: currentVersion) {
                present(release)
            } else if userInitiated {
                alert(String(localized: "已是最新版本"), String(localized: "当前版本 \(currentVersion)。"))
            }
        } catch {
            if userInitiated { alert(String(localized: "检查更新失败"), error.localizedDescription) }
        }
    }

    /// 返回 nil 表示还没有发布任何版本（GitHub 仓库没有 Release 时接口返回 404）。
    nonisolated static func fetchLatest(from url: URL) async throws -> Release? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        }
        if let github = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            let tag = github.tag_name
            let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
            let notes = github.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Release(version: version, url: github.html_url, notes: notes?.isEmpty == false ? notes : nil)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private static func present(_ release: Release) {
        NSApp.activate()
        if makeAlert(release).runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.url)
        }
    }

    /// 更新说明放在下面一块可以滚动的区域里，说明再长按钮也不会被挤出屏幕；只显示界面语言的那一半。
    static func makeAlert(_ release: Release) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "发现新版本 \(release.version)")
        alert.informativeText = String(localized: "当前版本 \(currentVersion)。")
        alert.addButton(withTitle: String(localized: "下载"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        if let notes = release.notes {
            let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
            alert.accessoryView = notesView(ReleaseNotes.localized(notes, chinese: chinese))
        }
        return alert
    }

    private static let notesWidth: CGFloat = 420
    private static let notesMaxHeight: CGFloat = 300

    private static func notesView(_ notes: String) -> NSView {
        let inset = NSSize(width: 6, height: 8)
        let width = notesWidth
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false
        // 不能选中：能选中时提示框一打开焦点就落在说明上，说明会被滚到中间
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = inset
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(formatted(notes))

        var contentHeight = notesMaxHeight
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            contentHeight = ceil(layout.usedRect(for: container).height) + inset.height * 2
        }
        // 内容不多时按内容的高度，多了就在这块区域里滚动，按钮始终看得见
        let height = min(notesMaxHeight, contentHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, contentHeight))
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView

        // 浅色底，看得出这是一块单独的、可以滚动的区域
        let box = NSBox(frame: scrollView.frame)
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 8
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = .zero
        box.contentView = scrollView
        return box
    }

    /// "- " 开头的行显示成项目符号（折行和文字对齐），行内的 `代码`、**粗体** 按 Markdown 显示。
    private static func formatted(_ notes: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString()
        for (index, rawLine) in notes.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            var line = rawLine
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "•\t" + line.dropFirst(2)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
                paragraph.headIndent = 12
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let parsed = (try? NSMutableAttributedString(AttributedString(markdown: line, options: options)))
                ?? NSMutableAttributedString(string: line)
            let range = NSRange(location: 0, length: parsed.length)
            parsed.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: range)
            // Markdown 里的代码用等宽字体，粗体加粗
            parsed.enumerateAttribute(.inlinePresentationIntent, in: range) { value, subrange, _ in
                guard let raw = value as? UInt else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                if intent.contains(.code) {
                    parsed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
                                        range: subrange)
                } else if intent.contains(.stronglyEmphasized) {
                    parsed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: subrange)
                }
            }
            result.append(parsed)
        }
        return result
    }

    private static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
