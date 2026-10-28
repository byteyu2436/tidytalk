@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import TidytalkCore

/// 一场会议（设计稿「详情 · 会议」）：页头只放位置和操作（拷贝全文、导出、更多）。内容区从上到下：
/// 标题和属性、提示条、播放条、标签和说话人、原始记录或 AI 总结。
struct MeetingDetailView: View {
    enum Tab: Hashable { case transcript, summary }

    let id: UUID
    let meetings: MeetingController
    let navigation: MainNavigation
    var onOpenSettings: (MainNavigation.SettingsPage) -> Void = { _ in }

    @ViewState private var title = ""
    @ViewState private var confirmDelete = false
    @ViewState private var player = MeetingPlayer()
    /// 刚删掉的一句，底部提示里可以撤销
    @ViewState private var undo: MeetingSegment?
    /// 等用户确认的重新分说话人：nil 不显示确认框；.some(nil) 自动判断人数；.some(n) 对方 n 个人
    @ViewState private var pendingRedo: Int??

    private var store: MeetingStore { meetings.store }
    private var processor: MeetingProcessor { meetings.processor }

    var body: some View {
        if let meeting = store.meeting(id) {
            VStack(spacing: 0) {
                headerBar(meeting)
                PageBody(scrolls: false) {
                    header(meeting)
                    banners(meeting)
                    if player.canPlay(meeting) {
                        MeetingPlayerBar(player: player)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        tabRow(meeting)
                        switch navigation.meetingTab {
                        case .transcript:
                            if meeting.segments.isEmpty {
                                EmptyState(symbol: "text.bubble", tint: Theme.Tint.meeting,
                                           title: processor.isProcessing(id) ? String(localized: "正在整理文字…")
                                               : String(localized: "这场会议没有识别到说话的内容"))
                            } else {
                                TranscriptList(meeting: meeting, player: player, actions: actions)
                            }
                        case .summary:
                            MeetingSummaryView(meeting: meeting, meetings: meetings, onOpenSettings: onOpenSettings)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .onAppear {
                title = meeting.title
                player.load(meeting, store: store)
            }
            .onChange(of: id) {
                title = store.meeting(id)?.title ?? ""
                if let meeting = store.meeting(id) { player.load(meeting, store: store) }
            }
            .onChange(of: meeting.hasRecording) { player.load(meeting, store: store, force: true) }
            .onDisappear { player.stop() }
            .onChange(of: navigation.exportRequest) {
                guard let (url, format) = ExportPanel.run(name: meeting.title) else { return }
                do {
                    try MeetingExport.render(meeting, as: format).write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            .overlay(alignment: .bottom) { undoToast }
            .confirmationDialog("重新分对方的说话人？", isPresented: Binding(get: { pendingRedo != nil },
                                                                            set: { if !$0 { pendingRedo = nil } })) {
                Button("重新分") {
                    if let speakers = pendingRedo { processor.process(id, remoteSpeakers: speakers) }
                    pendingRedo = nil
                }
            } message: {
                Text("会按录音重新识别对方的话，你手动改过的文字和说话人会被替换。")
            }
            .confirmationDialog("删除这场会议？", isPresented: $confirmDelete) {
                Button("删除会议和录音", role: .destructive) {
                    navigation.closeRecord()
                    store.delete(id)
                }
            } message: {
                Text("文字、总结和录音都会删除，不能恢复。")
            }
        } else {
            RecordGoneView(navigation: navigation)
        }
    }

    // MARK: - 修改会议记录

    private var actions: TranscriptActions {
        TranscriptActions(
            rename: { speaker, name in store.update(id) { $0.rename(speaker: speaker, to: name) } },
            edit: { segment, text in store.update(id) { $0.updateText(of: segment, to: text) } },
            delete: { segment in
                var removed: MeetingSegment?
                store.update(id) { removed = $0.deleteSegment(segment) }
                withAnimation { undo = removed }
            },
            reassign: { segment, speaker in
                store.update(id) { meeting in
                    let target = speaker ?? meeting.addSpeaker(
                        source: meeting.segments.first { $0.id == segment }?.source ?? .system)
                    meeting.reassign(segment, to: target)
                }
            })
    }

    /// 删掉一句后在底部提示 5 秒，可以撤销。
    @ViewBuilder
    private var undoToast: some View {
        if let segment = undo {
            Toast(text: String(localized: "已删除一句")) {
                IconButton("arrow.uturn.backward", help: "撤销（⌘Z）", size: 26, tint: Theme.accentText) {
                    store.update(id) { $0.restore(segment) }
                    withAnimation { undo = nil }
                }
                .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: segment.id) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation { if undo?.id == segment.id { undo = nil } }
            }
        }
    }

    // MARK: - 头部

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题太长时换行，最多三行
            TextField("会议标题", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(Theme.title)
                .tracking(Theme.titleTracking)
                .foregroundStyle(Theme.text)
                .onSubmit { saveTitle() }
                .onChange(of: title) { saveTitle() }
            ChipRow(spacing: 8) {
                let status = status(meeting)
                PropertyChip(symbol: status.symbol, text: status.text, tint: status.color)
                PropertyChip(symbol: "calendar", text: TranscribeFormat.chipDate(meeting.startedAt))
                PropertyChip(symbol: "timer", text: MeetingFormat.duration(meeting.duration))
                if meeting.activeSpeakers.count > 1 {
                    PropertyChip(symbol: "person.2", text: String(localized: "\(String(meeting.activeSpeakers.count)) 人"),
                                 tint: Theme.Tint.meeting)
                }
                if meeting.summary != nil {
                    PropertyChip(symbol: "sparkles", text: String(localized: "已总结"), tint: Theme.Tint.ai)
                }
                if meeting.hasRecording {
                    PropertyChip(symbol: "lock", text: String(localized: "录音在这台 Mac 上"), tint: Theme.Tint.local)
                } else if meeting.state != .recording {
                    PropertyChip(symbol: "mic.slash", text: String(localized: "录音已删除"))
                }
            }
        }
    }

    private func status(_ meeting: Meeting) -> (symbol: String, text: String, color: Color) {
        if processor.progress[id] != nil { return ("rays", String(localized: "正在整理"), Theme.Tint.progress) }
        switch meeting.state {
        case .recording: return ("record.circle", String(localized: "正在记录"), Theme.Tint.recording)
        case .processing: return ("rays", String(localized: "正在整理"), Theme.Tint.progress)
        case .failed: return ("exclamationmark.circle", String(localized: "处理失败"), Theme.danger)
        case .ready: return ("checkmark.circle", String(localized: "已完成"), Theme.Tint.local)
        }
    }

    private func headerBar(_ meeting: Meeting) -> some View {
        PageHeader {
            Breadcrumb(parent: navigation.section.title, title: meeting.title) { navigation.closeRecord() }
        } trailing: {
            IconButton("doc.on.doc", help: "拷贝全文") { copy(MeetingExport.render(meeting, as: .text)) }
            IconMenu(symbol: "square.and.arrow.up", help: "导出") {
                ForEach(TranscriptExport.Format.allCases, id: \.self) { format in
                    Button(format.title) { export(meeting, as: format) }
                }
            }
            IconMenu(symbol: "ellipsis", help: "更多") {
                speakerMenu(meeting)
                Divider()
                Button("删除录音，保留文字") {
                    player.stop()
                    store.deleteRecording(id)
                }
                .disabled(!meeting.hasRecording || processor.isProcessing(id))
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)]) }
                Divider()
                Button("删除会议…", role: .destructive) { confirmDelete = true }
            }
        }
    }

    /// 标签（原始记录 / AI 总结）和右边的说话人（点一下改名）。
    private func tabRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            LinearTabs(selection: Binding(get: { navigation.meetingTab }, set: { navigation.meetingTab = $0 }),
                       items: [.init(value: Tab.transcript, title: String(localized: "原始记录")),
                               .init(value: Tab.summary, title: String(localized: "AI 总结"), symbol: "sparkles",
                                     tint: Theme.Tint.ai)])
            Spacer(minLength: 8)
            if navigation.meetingTab == .transcript, meeting.activeSpeakers.count > 1, !processor.isProcessing(id) {
                SpeakerBar(meeting: meeting) { speaker, name in store.update(id) { $0.rename(speaker: speaker, to: name) } }
            }
        }
    }

    @ViewBuilder
    private func speakerMenu(_ meeting: Meeting) -> some View {
        let canRedo = meeting.hasRecording && meeting.state != .recording && !processor.isProcessing(id)
            && processor.diarizationReady
        Menu("重新分对方的说话人") {
            Button("自动判断人数") { pendingRedo = .some(nil) }
            Divider()
            ForEach(2...6, id: \.self) { count in
                Button("对方 \(count) 个人") { pendingRedo = .some(count) }
            }
        }
        .disabled(!canRedo)
    }

    @ViewBuilder
    private func banners(_ meeting: Meeting) -> some View {
        if let progress = processor.progress[id] {
            AlertBar(symbol: "rays", tint: Theme.Tint.progress, spinning: true,
                     title: String(localized: "正在整理：\(progress.stage)"),
                     message: String(localized: "整理完之前可以先看会议中识别的文字，说话人会在整理完后补上。")) {
                ThinProgress(fraction: progress.fraction, tint: Theme.Tint.progress).frame(width: 160)
            }
        } else if meeting.state == .failed {
            let reason = meeting.processingError ?? ""
            AlertBar(symbol: "exclamationmark.triangle", tint: Theme.danger, title: String(localized: "会后整理失败"),
                     message: String(localized: "\(reason)。下面是会议中识别的文字，可以重新整理一次。")) {
                IconButton("arrow.clockwise", help: "重新整理这场会议", outlined: true) { processor.process(id) }
                    .disabled(!meeting.hasRecording)
            }
        } else if processor.diarizeEnabled, !processor.diarizationModels.isReady, meeting.hasRecording {
            DiarizationModelBanner(manager: processor.diarizationModels) {
                processor.process(id)
            }
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.meeting(id)?.title != trimmed else { return }
        store.update(id) { $0.title = trimmed }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ meeting: Meeting, as format: TranscriptExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingExport.render(meeting, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// 参会的人：头像和名字，点一下改名（设计稿：高 28 的圆角标签，头像 20）。
struct SpeakerBar: View {
    let meeting: Meeting
    let onRename: (String, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(meeting.activeSpeakers) { speaker in
                    RenameButton(speaker: speaker, onRename: onRename) {
                        HStack(spacing: 6) {
                            SpeakerAvatar(speaker: speaker, color: SpeakerColors.color(for: speaker.id, in: meeting), size: 20)
                            Text(speaker.name).font(Theme.smallMedium).foregroundStyle(Theme.text)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 10)
                        .frame(height: 28)
                        .overlay(Capsule().strokeBorder(Theme.border))
                        .contentShape(Capsule())
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 没有下载说话人模型时的提示（蓝色）：下载后自动重新整理这场会议，可以分出对方的多个人。
struct DiarizationModelBanner: View {
    let manager: ModelManager
    let onReady: () -> Void

    var body: some View {
        Group {
            switch manager.status {
            case .downloading(let fraction, _):
                AlertBar(symbol: "person.2", tint: Theme.Tint.meeting,
                         title: String(localized: "正在下载说话人模型 \(Int(fraction * 100))%"),
                         message: String(localized: "下载完会自动重新整理这场会议。")) {
                    ThinProgress(fraction: fraction, tint: Theme.Tint.meeting).frame(width: 160)
                }
            case .verifying:
                AlertBar(symbol: "person.2", tint: Theme.Tint.meeting, title: String(localized: "正在校验说话人模型…")) {
                    ThinProgress(fraction: nil, tint: Theme.Tint.meeting).frame(width: 160)
                }
            case .ready:
                AlertBar(symbol: "person.2", tint: Theme.Tint.meeting, title: String(localized: "说话人模型已就绪"),
                         message: String(localized: "重新整理这场会议，就能分出对方的多个人。")) {
                    IconButton("arrow.clockwise", help: "重新整理这场会议", tint: Theme.Tint.meeting, outlined: true,
                               action: onReady)
                }
            default:
                AlertBar(symbol: "person.2", tint: Theme.Tint.meeting,
                         title: String(localized: "下载说话人模型后，可以分出对方的多个人"),
                         message: String(localized: "约 \(ByteCountFormatter.string(fromByteCount: manager.totalSize ?? 0, countStyle: .file))，从 Hugging Face 下载。下载完会自动重新整理这场会议。")) {
                    IconButton("arrow.down.to.line", help: "下载说话人模型", tint: Theme.Tint.meeting, outlined: true) {
                        manager.download()
                    }
                }
            }
        }
        // 下载、校验完自动重新整理
        .onChange(of: manager.isReady) { if manager.isReady { onReady() } }
    }
}

/// 整场会议的播放条（设计稿：黑色圆形播放键 32、进度条高 6、右边是速度）。“我”和“对方”两路录音一起放。
struct MeetingPlayerBar: View {
    let player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accentForeground)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? String(localized: "暂停") : String(localized: "播放"))
            Text(MeetingFormat.clock(player.currentTime))
                .font(Theme.smallMedium.monospacedDigit())
                .foregroundStyle(Theme.text)
            ScrubBar(value: player.currentTime, total: player.duration) { player.seek(to: $0) }
            Text(MeetingFormat.clock(player.duration))
                .font(Theme.small.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Button(action: player.cycleRate) {
                Text(verbatim: player.rate == 1 ? "1×" : player.rate == 1.5 ? "1.5×" : "2×")
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
            .help("播放速度")
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .cardStyle()
    }
}

// MARK: - 原始记录

/// 会议记录上可以做的修改；录制中的实时界面不传，只能看。
struct TranscriptActions {
    var rename: (String, String) -> Void
    var edit: (Int, String) -> Void
    var delete: (Int) -> Void
    /// 改给哪个人；nil 表示新加一个说话人
    var reassign: (Int, String?) -> Void
}

/// 会议记录：同一个人连着说的几段合在一起，只在开头显示头像和名字；时间、回放和编辑按钮在鼠标移上去时出现。
struct TranscriptList: View {
    let meeting: Meeting
    var player: MeetingPlayer?
    var followLatest = false
    var actions: TranscriptActions?
    /// 开会中：说完了、还在识别的那几路，列表最后显示灰色的“正在识别……”
    var recognizing: [MeetingSource] = []

    /// 正在播放的那一句
    private var playing: Int? {
        guard let player, player.hasStarted else { return nil }
        return meeting.segments.filter { $0.start <= player.currentTime + 0.05 }.max { $0.start < $1.start }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(TranscriptGroup.make(meeting.segments)) { group in
                        TranscriptGroupView(meeting: meeting, group: group, player: player, playing: playing,
                                            actions: actions)
                            .id(group.id)
                    }
                    ForEach(recognizing, id: \.self) { source in
                        RecognizingRow(meeting: meeting, source: source).id("recognizing-\(source.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onChange(of: meeting.segments.count) {
                if followLatest, let last = TranscriptGroup.make(meeting.segments).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

/// 同一组说话人连着说的几段话。
struct TranscriptGroup: Identifiable {
    let id: Int
    let speakerIDs: [String]
    let segments: [MeetingSegment]

    static func make(_ segments: [MeetingSegment]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let last = groups.last, last.speakerIDs == segment.speakerIDs {
                groups[groups.count - 1] = TranscriptGroup(id: last.id, speakerIDs: last.speakerIDs,
                                                           segments: last.segments + [segment])
            } else {
                groups.append(TranscriptGroup(id: segment.id, speakerIDs: segment.speakerIDs, segments: [segment]))
            }
        }
        return groups
    }
}

struct TranscriptGroupView: View {
    let meeting: Meeting
    let group: TranscriptGroup
    let player: MeetingPlayer?
    var playing: Int?
    let actions: TranscriptActions?

    private var speakers: [MeetingSpeaker] { group.speakerIDs.compactMap { meeting.speaker($0) } }
    private var isPlaying: Bool { group.segments.contains { $0.id == playing } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarStack(meeting: meeting, speakers: speakers, size: speakers.count > 1 ? 20 : 28)
                .frame(width: 28, height: 28, alignment: speakers.count > 1 ? .topLeading : .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                            if index > 0 { Text(String(localized: "、")).font(Theme.bodySemibold).foregroundStyle(Theme.text) }
                            if let actions {
                                RenameButton(speaker: speaker, onRename: actions.rename) { name(speaker) }
                            } else {
                                name(speaker)
                            }
                        }
                    }
                    Text(TranscriptExport.clock(group.segments[0].start))
                        .font((isPlaying ? Theme.smallMedium : Theme.small).monospacedDigit())
                        .foregroundStyle(isPlaying ? Theme.text : Theme.secondaryText)
                    if group.speakerIDs.count > 1 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.Tint.progress)
                            Text("同时在说").font(Theme.micro).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
                        .help("几个人同时在说话，这段文字是混在一起识别出来的")
                    }
                    if isPlaying {
                        Image(systemName: "speaker.wave.2").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Tint.meeting)
                    }
                }
                ForEach(group.segments) { segment in
                    SegmentText(meeting: meeting, segment: segment, player: player, actions: actions)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isPlaying ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func name(_ speaker: MeetingSpeaker) -> some View {
        Text(speaker.name)
            .font(Theme.bodySemibold)
            .foregroundStyle(Theme.text)
    }
}

/// 一段话：鼠标移上去时右边出现回放、编辑和更多操作（改说话人、拷贝、删除）。双击文字直接编辑。
struct SegmentText: View {
    let meeting: Meeting
    let segment: MeetingSegment
    let player: MeetingPlayer?
    let actions: TranscriptActions?
    @ViewState private var hovering = false
    @ViewState private var editing = false
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                editor
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(segment.text)
                        .font(Theme.reading)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { if actions != nil { startEditing() } }
                    tools
                        .opacity(hovering ? 1 : 0)
                }
            }
        }
        .background(editing ? Theme.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { hovering = $0 }
        .contextMenu { if actions != nil { menuItems } }
    }

    @ViewBuilder
    private var tools: some View {
        HStack(spacing: 2) {
            if let player, player.canPlay(meeting) {
                IconButton("play", help: "从这一句开始放", size: 24) { player.play(from: segment.start) }
            }
            if actions != nil {
                IconButton("pencil", help: "编辑这一句", size: 24, action: startEditing)
                IconMenu(symbol: "ellipsis", help: "更多", size: 24) { menuItems }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let actions {
            Button("编辑…", action: startEditing)
            Menu("改成谁说的") {
                ForEach(meeting.speakers) { speaker in
                    Button(speaker.name) { actions.reassign(segment.id, speaker.id) }
                        .disabled(segment.speakerIDs == [speaker.id])
                }
                Divider()
                Button("新的说话人") { actions.reassign(segment.id, nil) }
            }
            Button("拷贝这一句") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
            Divider()
            Button("删除这一句", role: .destructive) { actions.delete(segment.id) }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.reading)
                .lineSpacing(8)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand { editing = false }
            HStack(spacing: 6) {
                Text("回车保存，Esc 取消").font(Theme.small).foregroundStyle(Theme.secondaryText)
                IconButton("xmark", help: "取消（Esc）", size: 28) { editing = false }
                IconButton("checkmark", help: "保存（回车）", size: 28, prominent: true, action: save)
            }
        }
        .padding(8)
    }

    private func startEditing() {
        draft = segment.text
        editing = true
        focused = true
    }

    private func save() {
        actions?.edit(segment.id, draft)
        editing = false
    }
}

/// 说话人头像：带颜色的圆，里面是"我"、编号或名字的第一个字。
struct SpeakerAvatar: View {
    let speaker: MeetingSpeaker
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        if speaker.customName == nil {
            switch speaker.role {
            case .remote(let n), .room(let n): return String(n)
            default: break
            }
        }
        return speaker.name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// 几个头像叠在一起（同时说话的几个人、列表里的参会人）。
struct AvatarStack: View {
    let meeting: Meeting
    let speakers: [MeetingSpeaker]
    var size: CGFloat = 28
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(speakers.prefix(limit)) { speaker in
                SpeakerAvatar(speaker: speaker, color: SpeakerColors.color(for: speaker.id, in: meeting), size: size)
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: size > 20 ? 2 : 1.5))
            }
        }
    }
}

/// 点一下给说话人改名（这场会议里所有地方一起改）。
struct RenameButton<Label: View>: View {
    let speaker: MeetingSpeaker
    let onRename: (String, String) -> Void
    @ViewBuilder let label: () -> Label
    @ViewState private var editing = false
    @ViewState private var name = ""

    var body: some View {
        Button {
            name = speaker.customName ?? ""
            editing = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .help("点击改名")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("给\(speaker.name)改名").font(Theme.heading)
                TextField(speaker.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                HStack {
                    Text("留空恢复默认名字").font(Theme.small).foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    IconButton("checkmark", help: "好（回车）", size: 24, prominent: true, action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        onRename(speaker.id, name)
        editing = false
    }
}

enum SpeakerColors {
    /// 不用红色：红色在界面上表示正在录音和出错
    private static let palette: [Color] = [0xE5853B, 0x3E9F68, 0x9468D4, 0x2A9FB4, 0xD25F97, 0xB8962A, 0x6577A0, 0x35A893]
        .map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }

    /// "我"用强调色，其他人按在会议里出现的顺序取不同的颜色。
    static func color(for id: String, in meeting: Meeting) -> Color {
        if id == MeetingSpeaker.me.id { return Theme.Tint.meeting }
        let others = meeting.speakers.filter { $0.id != MeetingSpeaker.me.id }
        let index = others.firstIndex { $0.id == id } ?? 0
        return palette[index % palette.count]
    }
}

/// 播放整场会议：“我”和“对方”两路录音一起放，可以拖进度、换速度；点某一句从那里开始放。
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    /// 放过（之后才高亮正在放的那一句）
    private(set) var hasStarted = false

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loaded: UUID?

    func canPlay(_ meeting: Meeting) -> Bool {
        meeting.hasRecording && meeting.state != .recording && meeting.state != .processing
    }

    func load(_ meeting: Meeting, store: MeetingStore, force: Bool = false) {
        guard force || loaded != meeting.id else { return }
        stop()
        loaded = meeting.id
        guard canPlay(meeting) else { return }
        players = MeetingSource.allCases.compactMap { try? AVAudioPlayer(contentsOf: store.audioURL(meeting.id, $0)) }
        for player in players {
            player.enableRate = true
            player.prepareToPlay()
        }
        duration = max(meeting.duration, players.map(\.duration).max() ?? 0)
    }

    func toggle() {
        isPlaying ? pause() : play(from: currentTime >= duration - 0.2 ? 0 : currentTime)
    }

    func play(from time: TimeInterval) {
        guard let first = players.first else { return }
        // 两路同时开始，免得一前一后
        let start = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(time, player.duration)
            player.rate = rate
            player.play(atTime: start)
        }
        currentTime = time
        isPlaying = true
        hasStarted = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to time: TimeInterval) {
        if isPlaying {
            play(from: time)
        } else {
            currentTime = time
            hasStarted = true
        }
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        players.forEach { $0.rate = rate }
    }

    func stop() {
        pause()
        players = []
        loaded = nil
        currentTime = 0
        duration = 0
        hasStarted = false
    }

    private func tick() {
        currentTime = players.map(\.currentTime).max() ?? currentTime
        if !players.contains(where: \.isPlaying) {
            pause()
            if currentTime >= duration - 0.3 { currentTime = 0 }
        }
    }
}

// MARK: - AI 总结

struct MeetingSummaryView: View {
    let meeting: Meeting
    let meetings: MeetingController
    var onOpenSettings: (MainNavigation.SettingsPage) -> Void = { _ in }

    @ViewState private var editing = false
    @ViewState private var draft = ""
    @ViewState private var confirmDelete = false

    private var processor: MeetingProcessor { meetings.processor }
    private var config: AIConfig { processor.aiConfig }

    var body: some View {
        Group {
            if editing {
                editor
            } else if processor.summarizing.contains(meeting.id) {
                EmptyState(symbol: "sparkles", tint: Theme.Tint.ai, title: String(localized: "正在生成总结…"),
                           message: String(localized: "\(MeetingProcessor.serviceName(config)) 正在整理，长会议要一两分钟。可以先去做别的，好了会出现在这里。")) {
                    ThinProgress(fraction: nil, tint: Theme.Tint.ai).frame(width: 160)
                }
            } else if let summary = meeting.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(SummarySection.parse(summary.markdown).enumerated()), id: \.offset) { _, section in
                            SummaryCard(section: section)
                        }
                        footer(summary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = processor.summaryErrors[meeting.id] {
                AlertBar(symbol: "exclamationmark.triangle", tint: Theme.danger, title: String(localized: "总结失败"),
                         message: error) {
                    IconButton("arrow.clockwise", help: "重新生成", tint: Theme.Tint.ai, outlined: true) {
                        processor.summarize(meeting.id)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func footer(_ summary: MeetingSummary) -> some View {
        HStack(spacing: 8) {
            if summary.isPartial {
                Label("有部分内容没有写完", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TightLabelStyle())
                    .foregroundStyle(Theme.Tint.progress)
            }
            Label(String(localized: "\(summary.service) 生成于 \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))"),
                  systemImage: "sparkles")
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            IconButton("pencil", help: "编辑总结", size: 28) {
                draft = summary.markdown
                editing = true
            }
            IconButton("doc.on.doc", help: "拷贝总结", size: 28) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.markdown, forType: .string)
            }
            IconButton("arrow.clockwise", help: "重新生成", size: 28, tint: Theme.Tint.ai) { processor.summarize(meeting.id) }
                .disabled(!config.isConfigured || meeting.segments.isEmpty)
            IconMenu(symbol: "ellipsis", help: "更多", size: 28) {
                Button("删除总结…", role: .destructive) { confirmDelete = true }
            }
        }
        .font(Theme.small)
        .confirmationDialog("删除这份总结？", isPresented: $confirmDelete) {
            Button("删除总结", role: .destructive) { meetings.store.update(meeting.id) { $0.summary = nil } }
        } message: {
            Text("会议记录和录音不受影响，之后可以重新生成。")
        }
    }

    /// 直接改总结的 Markdown（标题用 ## 开头，待办用 - [ ] 开头）。
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft)
                .font(.system(size: 13).monospaced())
                .scrollContentBackground(.hidden)
                .padding(12)
                .cardStyle()
            HStack {
                Text("用 Markdown 写：## 开头是小节标题，- 开头是列表，- [ ] 开头是待办。")
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton("xmark", help: "取消（Esc）") { editing = false }
                    .keyboardShortcut(.cancelAction)
                IconButton("checkmark", help: "保存（⌘S）", prominent: true) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    meetings.store.update(meeting.id) { meeting in
                        guard var summary = meeting.summary else { return }
                        summary.markdown = text
                        meeting.summary = text.isEmpty ? nil : summary
                    }
                    editing = false
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var emptyState: some View {
        EmptyState(symbol: "sparkles", tint: Theme.Tint.ai, title: String(localized: "把这场会议整理成要点、决定和待办"),
                   message: config.isConfigured ? MeetingProcessor.destination(config)
                       : String(localized: "总结需要 AI 服务。可以用本机的 Ollama、LM Studio 或 Apple 智能，文字不会离开这台 Mac。")) {
            if config.isConfigured {
                IconButton("sparkles", help: "生成总结", size: 40, tint: Theme.Tint.ai, prominent: true) {
                    processor.summarize(meeting.id)
                }
                .disabled(meeting.segments.isEmpty || processor.isProcessing(meeting.id))
            } else {
                IconButton("gearshape", help: "设置 AI 服务", size: 40, tint: Theme.Tint.ai, outlined: true) {
                    onOpenSettings(.ai)
                }
            }
        }
    }
}

/// AI 总结的一节：二级标题和下面的内容。没有标题的开头部分标题为空。
struct SummarySection {
    let title: String
    let lines: [String]

    static func parse(_ markdown: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        var title = ""
        var lines: [String] = []
        func flush() {
            let content = lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !title.isEmpty || !content.isEmpty { sections.append(SummarySection(title: title, lines: Array(content))) }
        }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flush()
                title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    /// 按标题里的关键词配图标（中英文都认），认不出的用通用图标。
    var symbol: String {
        let t = title.lowercased()
        let table: [(keys: [String], symbol: String)] = [
            (["概要", "摘要", "summary", "overview"], "text.alignleft"),
            (["要点", "讨论", "key", "point", "discussion"], "list.bullet"),
            (["决定", "结论", "decision"], "checkmark.seal"),
            (["待办", "行动", "action", "to-do", "todo"], "checklist"),
            (["待定", "问题", "open", "question", "follow"], "questionmark.circle"),
        ]
        return table.first { $0.keys.contains { t.contains($0) } }?.symbol ?? "sparkles"
    }

    /// 小节的颜色：概要紫（AI 写的）、要点蓝、决定绿（定下来了）、待办橙（要去做）、待定问题黄（还没定）
    var tint: Color {
        switch symbol {
        case "list.bullet": Theme.Tint.meeting
        case "checkmark.seal": Theme.Tint.history
        case "checklist": Theme.Tint.vocabulary
        case "questionmark.circle": Theme.Tint.progress
        default: Theme.Tint.ai
        }
    }
}

struct SummaryCard: View {
    let section: SummarySection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(section.title).font(Theme.captionSemibold).foregroundStyle(Theme.secondaryText)
            }
            MarkdownView(markdown: section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.reading)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
    }
}

/// 显示 AI 总结的 Markdown：标题、列表、待办勾选框和段落（行内的粗体、斜体、代码由系统处理）。
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("#") {
            let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            inline(text).font(Theme.captionSemibold).padding(.top, 4)
        } else if let rest = Self.strip(line, prefixes: ["- [ ] ", "* [ ] "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.borderStrong)
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                inline(rest)
            }
        } else if let rest = Self.strip(line, prefixes: ["- [x] ", "- [X] ", "* [x] "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.square.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                inline(rest)
            }
        } else if let rest = Self.strip(line, prefixes: ["- ", "* ", "• "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.secondaryText).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                inline(rest)
            }
            .padding(.leading, raw.hasPrefix("  ") ? 16 : 0)
        } else if line == "---" {
            Divider()
        } else {
            inline(line)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private static func strip(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return nil
    }
}
