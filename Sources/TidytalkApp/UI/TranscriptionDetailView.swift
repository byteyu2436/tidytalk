@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import TidytalkCore

/// 一条转写（设计稿「详情 · 转写」）：标题和属性、处理进度或出错提示、音频（可以回放、另存），以及带时间的文字。
/// 点时间从那里开始播放，双击文字可以修改。正在转写时页头右边只有一个红色的停止按钮。
struct TranscriptionDetailView: View {
    let id: UUID
    let controller: TranscribeController
    let navigation: MainNavigation

    @ViewState private var player = MediaPlayer()
    @ViewState private var confirmDelete = false

    private var store: TranscriptionStore { controller.store }
    private var isLive: Bool { controller.current == id }

    var body: some View {
        if let item = store.item(id) {
            let segments = isLive ? controller.segments : item.segments
            VStack(spacing: 0) {
                headerBar(item, segments: segments)
                ScrollViewReader { proxy in
                    PageBody {
                        header(item)
                        banners(item)
                        if item.state != .failed || store.audioURL(item) != nil {
                            MediaCard(item: item, store: store, player: player, isLive: isLive)
                        }
                        transcript(item, segments: segments)
                    }
                    .onChange(of: segments.count) {
                        // 转写过程中跟着最新的一句往下滚
                        if isLive, let last = segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            .onAppear { player.load(isLive ? nil : store.audioURL(item)) }
            .onChange(of: isLive) { player.load(isLive ? nil : store.audioURL(item)) }
            .onChange(of: item.audioFile) { player.load(isLive ? nil : store.audioURL(item)) }
            .onDisappear { player.stop() }
            .onChange(of: navigation.exportRequest) {
                guard !item.segments.isEmpty, let (url, format) = ExportPanel.run(name: item.exportName) else { return }
                do {
                    try TranscriptExport.render(item.segments, as: format, title: item.exportName)
                        .write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            .confirmationDialog("删除这条转写？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    player.stop()
                    navigation.closeRecord()
                    store.delete(id)
                }
            } message: {
                Text(TranscribeFormat.deleteMessage(item))
            }
        } else {
            RecordGoneView(navigation: navigation)
        }
    }

    // MARK: - 页头

    private func headerBar(_ item: Transcription, segments: [TranscriptSegment]) -> some View {
        PageHeader {
            Breadcrumb(parent: navigation.section.title, title: TranscribeFormat.title(item)) {
                navigation.closeRecord()
            }
        } trailing: {
            if isLive {
                IconButton("square", help: "停止转写，保留已经识别的部分", tint: Theme.Tint.recording, prominent: true) {
                    controller.cancel()
                }
            } else {
                if !segments.isEmpty {
                    IconButton("doc.on.doc", help: "拷贝全文") {
                        Clipboard.copy(TranscriptExport.render(segments, as: .text))
                    }
                    IconMenu(symbol: "square.and.arrow.up", help: "导出") {
                        ForEach(TranscriptExport.Format.allCases, id: \.self) { format in
                            Button(format.title) { export(item, as: format) }
                        }
                    }
                }
                IconMenu(symbol: "ellipsis", help: "更多") {
                    if let link = item.link, let url = URL(string: link) {
                        Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
                    }
                    Button("在访达中显示") { TranscribeFormat.reveal(item, in: store) }
                    if item.kind == .link {
                        Button("删除音频，保留文字") {
                            player.stop()
                            store.deleteAudio(id)
                        }
                        .disabled(item.audioFile == nil)
                    }
                    Divider()
                    Button("删除…", role: .destructive) { confirmDelete = true }
                }
            }
        }
    }

    // MARK: - 标题和属性

    private func header(_ item: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题太长时换行，最多三行
            TextField("标题", text: Binding(get: { item.title }, set: { value in store.update(id) { $0.title = value } }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(Theme.title)
                .tracking(Theme.titleTracking)
                .foregroundStyle(Theme.text)
            ChipRow(spacing: 8) {
                let status = statusChip(item)
                PropertyChip(symbol: status.symbol, text: status.text, tint: status.color)
                if let link = item.link, let url = URL(string: link) {
                    let brand = SiteBrand.style(item.host)
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        PropertyChip(symbol: brand.symbol, text: item.host ?? link, tint: brand.color)
                    }
                    .buttonStyle(.plain)
                    .help(link)
                }
                if let uploader = item.uploader {
                    PropertyChip(symbol: "person", text: uploader)
                }
                if let duration = item.duration {
                    PropertyChip(symbol: "timer", text: MeetingFormat.duration(duration))
                }
                PropertyChip(symbol: "calendar", text: TranscribeFormat.chipDate(item.createdAt))
                // 绿色：在这台 Mac 上识别
                PropertyChip(symbol: "lock", text: item.model, tint: Theme.Tint.local)
                    .help("在这台 Mac 上识别")
            }
        }
    }

    private func statusChip(_ item: Transcription) -> (symbol: String, text: String, color: Color) {
        if isLive { return ("rays", String(localized: "正在转写"), Theme.Tint.progress) }
        switch item.state {
        case .transcribing: return ("rays", String(localized: "正在转写"), Theme.Tint.progress)
        case .failed: return ("exclamationmark.circle", String(localized: "转写失败"), Theme.danger)
        case .finished:
            return item.isPartial ? ("pause.circle", String(localized: "只转写了前面一部分"), Theme.Tint.progress)
                : ("checkmark.circle", String(localized: "已完成"), Theme.Tint.local)
        }
    }

    @ViewBuilder
    private func banners(_ item: Transcription) -> some View {
        if isLive {
            AlertBar(symbol: "rays", tint: Theme.Tint.progress, spinning: true, title: controller.stage.description,
                     message: controller.stage == .fetchingInfo
                         ? String(localized: "视频网站有时要十几秒才回应。拿到标题和封面后会先显示出来。") : nil) {
                ThinProgress(fraction: controller.stage.fraction, tint: Theme.Tint.progress).frame(width: 160)
            }
        } else if item.state == .failed {
            let reason = item.error ?? String(localized: "转写失败")
            AlertBar(symbol: "exclamationmark.triangle", tint: Theme.danger,
                     title: String(localized: "没有转写完：\(reason)"),
                     message: item.kind == .link ? String(localized: "可以换一个链接，或者把视频下载下来拖进“转写”页。")
                         : String(localized: "可以换一个文件再试。")) {
                IconButton("arrow.clockwise", help: "重新转写", outlined: true) { retry(item) }
                    .disabled(controller.isBusy)
            }
        } else if item.isPartial {
            AlertBar(symbol: "info.circle", title: String(localized: "中途停止了，下面是前面一部分的文字。"))
        }
    }

    /// 重新转写一次：成功开始后删掉这条失败的记录。
    private func retry(_ item: Transcription) {
        let newID: UUID?
        if let link = item.link {
            newID = controller.transcribe(link: link)
        } else if let path = item.sourcePath {
            newID = controller.transcribe(file: URL(fileURLWithPath: path))
        } else {
            newID = nil
        }
        guard let newID else { return }
        let section = navigation.section
        store.delete(item.id)
        navigation.openTranscription(newID, from: section)
    }

    // MARK: - 文字

    @ViewBuilder
    private func transcript(_ item: Transcription, segments: [TranscriptSegment]) -> some View {
        if segments.isEmpty {
            if item.state == .failed {
                EmptyState(symbol: "doc.text", tint: Theme.secondaryText, title: String(localized: "没有文字"),
                           message: item.kind == .link ? String(localized: "没能下载音频，所以还没有识别。")
                               : String(localized: "没能读出这个文件的声音。"), fill: false)
                    .padding(.top, 40)
            } else if !isLive {
                Text("没有识别到说话的内容").font(Theme.body).foregroundStyle(Theme.secondaryText)
            }
        } else {
            let active = player.hasStarted ? segments.last(where: { $0.start <= player.currentTime + 0.05 })?.id : nil
            VStack(alignment: .leading, spacing: Theme.titleGap) {
                HStack(spacing: 8) {
                    Text("文字").font(Theme.heading).foregroundStyle(Theme.text)
                    Text(verbatim: String(segments.count)).font(Theme.caption).foregroundStyle(Theme.secondaryText)
                }
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(segments) { segment in
                        TranscriptionRow(segment: segment, active: active == segment.id,
                                         canPlay: player.isReady,
                                         onPlay: { player.play(from: segment.start) },
                                         onEdit: isLive ? nil : { text in store.update(id) { $0.updateText(of: segment.id, to: text) } })
                            .id(segment.id)
                    }
                }
            }
        }
    }

    private func export(_ item: Transcription, as format: TranscriptExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.exportName + "." + format.rawValue
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExport.render(item.segments, as: format, title: item.exportName)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // 磁盘满、没有写入权限时要告诉用户，否则会以为已经导出了
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "导出失败")
            alert.runModal()
        }
    }
}

/// 音频：封面或文件图标、文件名和大小、播放进度，以及在访达中显示、另存为。
struct MediaCard: View {
    let item: Transcription
    let store: TranscriptionStore
    let player: MediaPlayer
    let isLive: Bool

    private var audio: URL? { store.audioURL(item) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TranscriptionArtwork(item: item, store: store, placeholder: isLive && item.thumbnailFile == nil)
                // 链接还在读信息时先留出封面的位置，拿到封面后不跳动
                .frame(width: item.thumbnailFile != nil || (isLive && item.kind == .link) ? 128 : 64, height: 72)
                // 还没拿到封面图：占位图上闪光，表示还在加载
                .shimmering(isLive && item.thumbnailFile == nil)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(fileName)
                        .font(Theme.bodyMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if audio != nil {
                        IconButton("folder", help: "在访达中显示", size: 28, tint: Theme.Tint.meeting) {
                            TranscribeFormat.reveal(item, in: store)
                        }
                        if item.kind == .link {
                            IconButton("square.and.arrow.down", help: "把音频存储到…", size: 28, tint: Theme.Tint.speech) { saveAudio() }
                        }
                    }
                }
                .frame(minHeight: 28)
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if player.isReady {
                    PlayerBar(player: player)
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var fileName: String {
        switch item.kind {
        case .link: item.audioFile.map { _ in item.exportName + "." + (item.fileType?.lowercased() ?? "m4a") }
            ?? String(localized: "下载的音频")
        case .file: item.sourcePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "文件")
        }
    }

    private var detail: String {
        if isLive { return String(localized: "转写完成后可以在这里回放") }
        switch item.kind {
        case .link:
            guard item.audioFile != nil else { return String(localized: "已删除下载的音频，文字还在") }
            let size = item.audioSize.map(TranscribeFormat.size) ?? ""
            return [item.fileType, size, String(localized: "保存在这台 Mac 上")].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .file:
            guard audio != nil else { return String(localized: "找不到原文件，可能已经移动或删除") }
            return (item.sourcePath as NSString?)?.abbreviatingWithTildeInPath ?? ""
        }
    }

    private func saveAudio() {
        guard let audio else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.exportName + "." + audio.pathExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: audio, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// 播放按钮、当前时间和可以拖动的进度条（设计稿：黑色圆形播放键 24，进度条高 4）。
struct PlayerBar: View {
    let player: MediaPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accentForeground)
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? String(localized: "暂停") : String(localized: "播放"))
            Text(MeetingFormat.clock(player.currentTime))
                .font(Theme.smallMedium.monospacedDigit())
                .foregroundStyle(Theme.text)
            ScrubBar(value: player.currentTime, total: player.duration, height: 4) { player.seek(to: $0) }
            Text(MeetingFormat.clock(player.duration))
                .font(Theme.small.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// 可以点、可以拖的进度条：浅灰的轨道，播过的部分是主色。
struct ScrubBar: View {
    let value: TimeInterval
    let total: TimeInterval
    var height: CGFloat = 6
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fraction = total > 0 ? min(1, max(0, value / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtle)
                Capsule().fill(Theme.accent).frame(width: proxy.size.width * fraction)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard total > 0, proxy.size.width > 0 else { return }
                onSeek(total * min(1, max(0, drag.location.x / proxy.size.width)))
            })
        }
        .frame(height: 16)
    }
}

/// 转写的一句：左边是时间（点一下从这里播放），右边是文字；鼠标移上去出现编辑和拷贝，双击直接编辑。
struct TranscriptionRow: View {
    let segment: TranscriptSegment
    let active: Bool
    let canPlay: Bool
    let onPlay: () -> Void
    let onEdit: ((String) -> Void)?
    @ViewState private var hovering = false
    @ViewState private var editing = false
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onPlay) {
                Text(TranscriptExport.clock(segment.start))
                    .font((active ? Theme.smallMedium : Theme.small).monospacedDigit())
                    .foregroundStyle(active ? Theme.Tint.speech : hovering && canPlay ? Theme.text : Theme.secondaryText)
                    .frame(width: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? String(localized: "从这里播放") : "")
            if editing {
                editor
            } else {
                Text(segment.text)
                    .font(Theme.reading)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { if onEdit != nil { startEditing() } }
                HStack(spacing: 2) {
                    if onEdit != nil {
                        IconButton("pencil", help: "编辑这一句", size: 24, action: startEditing)
                    }
                    IconButton("doc.on.doc", help: "拷贝这一句", size: 24) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(segment.text, forType: .string)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(editing ? Theme.accent.opacity(0.07) : active ? Theme.subtle : hovering ? Theme.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.reading)
                .lineSpacing(4)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand { editing = false }
            HStack(spacing: 6) {
                Text("回车保存，Esc 取消").font(Theme.small).foregroundStyle(Theme.tertiaryText)
                IconButton("xmark", help: "取消（Esc）", size: 24) { editing = false }
                IconButton("checkmark", help: "保存（回车）", size: 24, prominent: true, action: save)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func startEditing() {
        draft = segment.text
        editing = true
        focused = true
    }

    private func save() {
        onEdit?(draft)
        editing = false
    }
}

/// 播放转写的音频（链接下载的文件或本机的原文件，视频文件只放声音）。
@MainActor
@Observable
final class MediaPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// 已经加载、可以播放
    private(set) var isReady = false
    /// 播放过（之后才高亮正在播的那一句）
    private(set) var hasStarted = false

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL?) {
        guard url != self.url || (url != nil && player == nil) else { return }
        stop()
        self.url = url
        guard let url else { return }
        let player = AVPlayer(url: url)
        self.player = player
        isReady = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                if time.seconds.isFinite { self.currentTime = time.seconds }
                if let item = player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite, total > 0 { self.duration = total }
                    // 系统不支持的格式（例如 WebM）放不了，不显示播放条
                    if item.status == .failed { self.isReady = false }
                }
                self.isPlaying = player.rate > 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
            }
        }
        Task {
            if let total = try? await player.currentItem?.asset.load(.duration).seconds, total.isFinite, total > 0 {
                duration = total
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            hasStarted = true
        }
    }

    func play(from time: TimeInterval) {
        guard let player else { return }
        seek(to: time)
        player.play()
        isPlaying = true
        hasStarted = true
    }

    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        url = nil
        isPlaying = false
        isReady = false
        hasStarted = false
        currentTime = 0
        duration = 0
    }
}
