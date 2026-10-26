import AppKit
import SwiftUI
import TidytalkCore
import UniformTypeIdentifiers

/// 主窗口的「转写」页：「文件」和「链接」两个标签，各自有输入的地方和转写过的卡片。点卡片进入详情。
struct TranscribeView: View {
    let controller: TranscribeController
    let navigation: MainNavigation

    @ViewState private var link = ""
    @ViewState private var targeted = false
    @ViewState private var deleting: Transcription?
    @FocusState private var linkFocused: Bool

    private var store: TranscriptionStore { controller.store }
    private var tab: MainNavigation.TranscribeTab { navigation.transcribeTab }
    private var kind: Transcription.Kind { tab == .file ? .file : .link }

    var body: some View {
        Group {
            if let id = navigation.transcription {
                TranscriptionDetailView(id: id, controller: controller, navigation: navigation)
            } else {
                VStack(spacing: 0) {
                    header
                    content
                }
            }
        }
        .onChange(of: controller.failure) {
            // 没能建成记录（下载失败、读不出文件）：回到对应的标签页显示原因
            guard let failure = controller.failure else { return }
            navigation.transcription = nil
            navigation.transcribeTab = failure.kind == .file ? .file : .link
        }
        .confirmationDialog("删除这条转写？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("删除", role: .destructive) { store.delete(item.id) }
        } message: { item in
            Text(TranscribeFormat.deleteMessage(item))
        }
    }

    // MARK: - 页头

    private var header: some View {
        PageHeader {
            PageTitle(title: String(localized: "转写"))
            LinearTabs(selection: Binding(get: { navigation.transcribeTab }, set: { navigation.transcribeTab = $0 }),
                       items: [.init(value: .file, title: String(localized: "文件"), count: store.items(of: .file).count),
                               .init(value: .link, title: String(localized: "链接"), count: store.items(of: .link).count)])
                .padding(.leading, 10)
        } trailing: {
            if !store.items.isEmpty {
                SearchField(text: Binding(get: { navigation.transcribeSearch }, set: { navigation.transcribeSearch = $0 }),
                            prompt: "搜索转写")
            }
        }
    }

    // MARK: - 内容

    private var filtered: [Transcription] {
        let items = store.items(of: kind)
        let query = navigation.transcribeSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || (item.uploader ?? "").localizedCaseInsensitiveContains(query)
                || item.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12, alignment: .top)]

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if tab == .file { dropZone } else { linkInput }
                if let failure = controller.failure, failure.kind == kind {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.Tint.failed) {
                        Text(failure.message).foregroundStyle(Theme.text).textSelection(.enabled)
                        Spacer()
                        IconButton("xmark", help: "关闭", size: 22) { controller.clearFailure() }
                    }
                }
                let items = filtered
                if items.isEmpty {
                    if navigation.transcribeSearch.isEmpty {
                        Text(tab == .file ? String(localized: "转写过的文件会保存在这里，可以随时回来查看、导出。")
                             : String(localized: "转写过的链接会保存在这里，下载的音频可以回放、另存。"))
                            .font(Theme.small)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        EmptyState(symbol: "magnifyingglass", tint: Theme.Tint.speech,
                                   title: String(localized: "没有找到“\(navigation.transcribeSearch)”"),
                                   message: String(localized: "会搜索标题、上传者和转写的文字。"))
                            .frame(height: 260)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: tab == .file ? String(localized: "全部文件") : String(localized: "全部链接"),
                                      count: items.count)
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                            ForEach(items) { item in
                                TranscriptionCard(item: item, store: store,
                                                  stage: controller.current == item.id ? controller.stage : nil,
                                                  onOpen: { navigation.transcription = item.id },
                                                  onDelete: { deleting = item })
                                    .contextMenu { menu(item) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard tab == .file, let url = urls.first(where: \.isFileURL) else { return false }
            transcribe(file: url)
            return true
        } isTargeted: { targeted = $0 && tab == .file }
    }

    @ViewBuilder
    private func menu(_ item: Transcription) -> some View {
        Button("打开") { navigation.transcription = item.id }
        if let link = item.link, let url = URL(string: link) {
            Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
        }
        Button("在访达中显示") { TranscribeFormat.reveal(item, in: store) }
        Divider()
        Button("删除…", role: .destructive) { deleting = item }
            .disabled(controller.current == item.id)
    }

    // MARK: - 输入

    /// 拖放区整块都能点，点了选择文件（不另外放按钮）。
    private var dropZone: some View {
        Button(action: chooseFile) {
            dropZoneContent
        }
        .buttonStyle(DropZoneStyle(targeted: targeted))
        .disabled(controller.isBusy)
        .help("选择文件")
    }

    private var dropZoneContent: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.Tint.speech)
                .frame(width: 42, height: 42)
                .background(Theme.Tint.speech.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("把音频或视频文件拖到这里，或点一下选择").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                // 模型名前后的空格由排版规则补上
                Text(Typography.format(String(localized: "MP3、M4A、WAV、MP4、MOV 等，最长 3 小时。在这台 Mac 上识别，使用\(controller.modelTitle)模型。")))
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 12)
            if controller.isBusy {
                HStack(spacing: 6) {
                    StatusIcon(kind: .progress(controller.stage.fraction), size: 12)
                    Text("正在转写另一个")
                }
                .font(Theme.small)
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private var linkInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // 认出是哪个网站时，图标换成网站的颜色
                let brand = SiteBrand.style(URL(string: link.trimmingCharacters(in: .whitespaces))?.host)
                HStack(spacing: 7) {
                    Image(systemName: brand.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(brand.color)
                    TextField("粘贴视频链接（YouTube、B 站等）", text: $link)
                        .textFieldStyle(.plain)
                        .focused($linkFocused)
                        .onSubmit(submitLink)
                }
                .linearField(focused: linkFocused)
                IconButton("arrow.right", help: "转写这个链接（回车）", size: 30, tint: Theme.Tint.speech, prominent: true,
                           action: submitLink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || controller.isBusy)
            }
            Text(YTDLP.isInstalled
                 ? String(localized: "只下载链接里的音频和封面图，保存在这台 Mac 上，可以随时删除。仅限你有权使用的内容。")
                 : String(localized: "第一次转写链接时，会先从 GitHub 下载开源的下载工具 yt-dlp（约 35 MB）。仅限你有权使用的内容。"))
                .font(Theme.small)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(16)
        .cardStyle()
    }

    private func submitLink() {
        guard !controller.isBusy else { return }
        if let id = controller.transcribe(link: link) {
            link = ""
            navigation.transcription = id
        }
    }

    private func transcribe(file url: URL) {
        if let id = controller.transcribe(file: url) { navigation.transcription = id }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(file: url)
    }
}

/// 一条转写的卡片：上面是封面（链接的视频封面，或文件类型的图标）和时长，下面是标题、来源和日期。
struct TranscriptionCard: View {
    let item: Transcription
    let store: TranscriptionStore
    /// 正在转写这一条时的进度
    let stage: TranscribeController.Stage?
    let onOpen: () -> Void
    let onDelete: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                TranscriptionArtwork(item: item, store: store)
                    .frame(height: 124)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = item.duration {
                            Text(MeetingFormat.clock(duration))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(height: 18)
                                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let stage {
                            ThinProgress(fraction: stage.fraction, tint: Theme.Tint.progress).frame(height: 3).clipShape(Rectangle())
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        StatusIcon(kind: TranscribeFormat.status(item, stage: stage), size: 13)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text(TranscribeFormat.title(item))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                    HStack(spacing: 6) {
                        TranscriptionSource(item: item)
                        Spacer(minLength: 6)
                        Text(TranscribeFormat.date(item.createdAt))
                            .font(Theme.small)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                    // 每张卡片都留出状态这一行，同一排的卡片一样高
                    status.frame(height: 16, alignment: .leading)
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .cardStyle(hovering: hovering)
            .overlay(alignment: .topTrailing) {
                IconMenu(symbol: "ellipsis", help: "更多", size: 24) {
                    if let link = item.link, let url = URL(string: link) {
                        Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
                    }
                    Button("在访达中显示") { TranscribeFormat.reveal(item, in: store) }
                    Divider()
                    Button("删除…", role: .destructive, action: onDelete)
                        .disabled(stage != nil)
                }
                .background(Theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.radius))
                .padding(8)
                .opacity(hovering ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var status: some View {
        if let stage {
            Text(stage.description)
                .font(Theme.small)
                .foregroundStyle(Theme.Tint.progress)
                .lineLimit(1)
        } else if item.state == .failed {
            Text(item.error ?? String(localized: "转写失败"))
                .font(Theme.small)
                .foregroundStyle(Theme.Tint.failed)
                .lineLimit(1)
        } else if item.isPartial {
            Text("只转写了前面一部分").font(Theme.small).foregroundStyle(Theme.tertiaryText)
        } else {
            Text(item.preview).font(Theme.small).foregroundStyle(Theme.tertiaryText).lineLimit(1)
        }
    }
}

/// 来源：链接显示网站（和上传者），文件显示类型。
struct TranscriptionSource: View {
    let item: Transcription

    var body: some View {
        let style = TranscribeFormat.style(item)
        HStack(spacing: 5) {
            Image(systemName: style.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.color)
            Text(label).lineLimit(1).foregroundStyle(Theme.secondaryText)
        }
        .font(Theme.small)
    }

    private var label: String {
        switch item.kind {
        case .link: [item.host, item.uploader].compactMap { $0 }.joined(separator: " · ")
        case .file: item.fileType ?? String(localized: "文件")
        }
    }
}

/// 卡片和详情页上的封面：有视频封面就显示封面，否则是文件类型的图标。
struct TranscriptionArtwork: View {
    let item: Transcription
    let store: TranscriptionStore

    var body: some View {
        if let url = store.thumbnailURL(item), let image = ThumbnailCache.image(url) {
            Color.clear.overlay {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        } else {
            let style = TranscribeFormat.style(item)
            ZStack {
                Theme.subtle
                style.color.opacity(0.1)
                Image(systemName: style.symbol)
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

/// 按下时变深、拖进文件时变成强调色的拖放区。
private struct DropZoneStyle: ButtonStyle {
    let targeted: Bool

    func makeBody(configuration: Configuration) -> some View {
        DropZoneBody(configuration: configuration, targeted: targeted)
    }
}

private struct DropZoneBody: View {
    let configuration: ButtonStyleConfiguration
    let targeted: Bool
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    var body: some View {
        let active = targeted || (hovering && enabled)
        configuration.label
            .background(targeted ? Theme.Tint.speech.opacity(0.08) : configuration.isPressed ? Theme.selected
                        : hovering && enabled ? Theme.hover : Theme.subtle,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(active ? Theme.Tint.speech : Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
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
    /// 状态图标：转写中按进度填满，出错红色，中途停止灰色，完成靛蓝。
    static func status(_ item: Transcription, stage: TranscribeController.Stage?) -> StatusIcon.Kind {
        if let stage { return .progress(stage.fraction) }
        switch item.state {
        case .transcribing: return .progress(nil)
        case .failed: return .failed
        case .finished: return item.isPartial ? .partial : .done
        }
    }

    /// 来源的图标和颜色：链接是网站的颜色，音频文件是转写的青色，视频文件橙色。
    static func style(_ item: Transcription) -> (symbol: String, color: Color) {
        switch item.kind {
        case .link: SiteBrand.style(item.host)
        case .file: item.isVideo ? ("film", Theme.Tint.video) : ("waveform", Theme.Tint.speech)
        }
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
