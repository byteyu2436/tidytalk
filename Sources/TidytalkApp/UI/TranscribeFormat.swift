import AppKit
import SwiftUI
import TidytalkCore
import UniformTypeIdentifiers

/// 卡片和详情页上的封面：有视频封面就显示封面，否则是文件类型的图标。
struct TranscriptionArtwork: View {
    let item: Transcription
    let store: TranscriptionStore
    /// 还在读视频信息、没有封面：灰色的占位（外面加闪光）
    var placeholder = false

    var body: some View {
        if placeholder {
            Theme.subtle
        } else if let url = store.thumbnailURL(item), let image = ThumbnailCache.image(url) {
            Color.clear.overlay {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        } else {
            let style = TranscribeFormat.style(item)
            ZStack {
                Theme.subtle
                style.color.opacity(0.1)
                Image(systemName: style.name)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(style.color)
            }
            .overlay(alignment: .topLeading) {
                if let type = item.fileType {
                    Text(verbatim: type)
                        .font(Theme.micro)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                        .padding(8)
                }
            }
        }
    }

}

/// 视频网站的图标和颜色，卡片和链接输入框上用。
enum SiteBrand {
    static func style(_ host: String?) -> (symbol: String, color: Color) {
        guard let host = host?.lowercased(), !host.isEmpty else { return ("link", Theme.Tint.neutral) }
        func brand(_ hex: Int) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return ("play.rectangle.fill", brand(0xFF0033)) }
        if host.hasSuffix("bilibili.com") || host == "b23.tv" { return ("tv.fill", brand(0x00AEEC)) }
        if host.hasSuffix("vimeo.com") { return ("play.circle.fill", brand(0x1AB7EA)) }
        if host.hasSuffix("douyin.com") || host.hasSuffix("tiktok.com") { return ("music.note", brand(0xFE2C55)) }
        if host.hasSuffix("x.com") || host.hasSuffix("twitter.com") { return ("play.square.fill", Theme.text) }
        return ("globe", Theme.Tint.neutral)
    }

    /// 资料库里显示的网站名：YouTube、B 站，其他网站显示域名。
    static func name(_ host: String?) -> String {
        guard let host = host?.lowercased(), !host.isEmpty else { return String(localized: "链接") }
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return "YouTube" }
        if host.hasSuffix("bilibili.com") || host == "b23.tv" { return String(localized: "B 站") }
        if host.hasSuffix("vimeo.com") { return "Vimeo" }
        if host.hasSuffix("douyin.com") { return String(localized: "抖音") }
        if host.hasSuffix("tiktok.com") { return "TikTok" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// 封面图读一次就留在内存里，卡片列表滚动时不用反复读磁盘。
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

enum TranscribeFormat {
    /// 列表里的图标：都是转写的青色，链接、音频文件、视频文件各一个图标（网站的颜色只用在详情页的属性标签上）。
    static func style(_ item: Transcription) -> (name: String, color: Color) {
        switch item.kind {
        case .link: ("link", Theme.Tint.speech)
        case .file: (item.isVideo ? "film" : "waveform", Theme.Tint.speech)
        }
    }

    /// 来源和长度：YouTube · 12 分钟、文件 · 34 分钟（资料库里前面再加“转写”）。
    static func source(_ item: Transcription) -> [String] {
        var parts = [item.kind == .link ? SiteBrand.name(item.host) : String(localized: "文件")]
        if let duration = item.duration { parts.append(MeetingFormat.duration(duration)) }
        return parts
    }

    /// 转写页列表的第二行：链接 · YouTube · 12 分钟、文件 · 34 分钟；正在转写写当前步骤，失败写原因。
    @MainActor
    static func meta(_ item: Transcription, controller: TranscribeController) -> String {
        let kind = item.kind == .link ? String(localized: "链接") : String(localized: "文件")
        if controller.current == item.id { return "\(kind) · \(controller.stage.description)" }
        if item.state == .failed { return "\(kind) · \(item.error ?? String(localized: "转写失败"))" }
        if item.kind == .link { return ([kind] + source(item)).joined(separator: " · ") }
        return ([kind] + source(item).dropFirst()).joined(separator: " · ")
    }

    /// 卡片和页头上的标题：链接还没拿到视频标题时显示网站。
    static func title(_ item: Transcription) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("http://") || title.hasPrefix("https://") {
            return item.state == .transcribing ? String(localized: "正在获取标题…") : (item.host ?? title)
        }
        return title.isEmpty ? String(localized: "未命名") : title
    }

    /// 今天 17:10、昨天 09:30、10月21日
    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "今天 \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        return date.formatted(.dateTime.month().day())
    }

    /// 属性标签上的日期：今年的不写年份（10月27日 10:00）
    static func chipDate(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month().day().hour().minute())
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func deleteMessage(_ item: Transcription) -> String {
        item.kind == .link ? String(localized: "文字、下载的音频和封面图都会删除，不能恢复。")
            : String(localized: "转写的文字会删除，不能恢复。原文件不受影响。")
    }

    /// 在访达中显示：链接显示下载的音频（没有时显示记录的目录），文件显示原文件。
    @MainActor
    static func reveal(_ item: Transcription, in store: TranscriptionStore) {
        let url = store.audioURL(item) ?? store.directory(for: item.id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// “文件 › 导出…”：存储面板下面可以选格式，换格式时文件名后缀跟着换。
@MainActor
enum ExportPanel {
    static func run(name: String) -> (url: URL, format: TranscriptExport.Format)? {
        let formats = TranscriptExport.Format.allCases
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        popup.selectItem(at: formats.firstIndex(of: .markdown) ?? 0)
        let switcher = FormatSwitcher(panel: panel, formats: formats)
        popup.target = switcher
        popup.action = #selector(FormatSwitcher.change(_:))
        let label = NSTextField(labelWithString: String(localized: "格式："))
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        panel.accessoryView = stack
        panel.nameFieldStringValue = "\(name).\(TranscriptExport.Format.markdown.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return withExtendedLifetime(switcher) { (url, formats[max(0, popup.indexOfSelectedItem)]) }
    }

    private final class FormatSwitcher: NSObject {
        weak var panel: NSSavePanel?
        let formats: [TranscriptExport.Format]

        init(panel: NSSavePanel, formats: [TranscriptExport.Format]) {
            self.panel = panel
            self.formats = formats
        }

        @MainActor @objc func change(_ sender: NSPopUpButton) {
            guard let panel, formats.indices.contains(sender.indexOfSelectedItem) else { return }
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(formats[sender.indexOfSelectedItem].rawValue)"
        }
    }
}
