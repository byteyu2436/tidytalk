@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import TidytalkCore

/// 一场会议：「原始记录」按说话人排好的每段话，「AI 总结」要点、决定和待办。
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
                VStack(alignment: .leading, spacing: 12) {
                    header(meeting)
                    banners(meeting)
                }
                .frame(maxWidth: Theme.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 6)
                switch navigation.meetingTab {
                case .transcript:
                    if meeting.segments.isEmpty {
                        EmptyState(symbol: "text.bubble", tint: Theme.Tint.meeting,
                                   title: processor.isProcessing(id) ? String(localized: "正在整理文字…")
                                       : String(localized: "这场会议没有识别到说话的内容"))
                    } else {
                        TranscriptList(meeting: meeting, player: player, store: store, actions: actions)
                    }
                case .summary:
                    MeetingSummaryView(meeting: meeting, meetings: meetings, onOpenSettings: onOpenSettings)
                }
            }
            .onAppear { title = meeting.title }
            .onChange(of: id) { title = store.meeting(id)?.title ?? "" }
            .onDisappear { player.stop() }
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
                    navigation.meeting = nil
                    store.delete(id)
                }
            } message: {
                Text("文字、总结和录音都会删除，不能恢复。")
            }
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
            TextField("会议标题", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.title)
                .foregroundStyle(Theme.text)
                .onSubmit { saveTitle() }
                .onChange(of: title) { saveTitle() }
            ChipRow {
                StatusChip(kind: status(meeting), text: statusText(meeting))
                PropertyChip(symbol: "calendar", text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                PropertyChip(symbol: "clock", text: MeetingFormat.duration(meeting.duration))
                if !meeting.activeSpeakers.isEmpty {
                    PropertyChip(symbol: "person.2", text: String(localized: "\(String(meeting.activeSpeakers.count)) 人"),
                                 tint: Theme.Tint.meeting)
                }
                if meeting.summary != nil {
                    PropertyChip(symbol: "sparkles", text: String(localized: "已总结"), tint: Theme.Tint.ai)
                }
                if meeting.hasRecording {
                    PropertyChip(symbol: "lock", text: String(localized: "录音在这台 Mac 上"), tint: Theme.Tint.local)
                }
            }
            if meeting.activeSpeakers.count > 1 {
                SpeakerBar(meeting: meeting) { speaker, name in store.update(id) { $0.rename(speaker: speaker, to: name) } }
            }
        }
    }

    private func status(_ meeting: Meeting) -> StatusIcon.Kind {
        if let progress = processor.progress[id] { return .progress(progress.fraction) }
        switch meeting.state {
        case .recording: return .recording
        case .processing: return .progress(nil)
        case .failed: return .failed
        case .ready: return .done
        }
    }

    private func statusText(_ meeting: Meeting) -> String {
        if processor.progress[id] != nil { return String(localized: "正在整理") }
        switch meeting.state {
        case .recording: return String(localized: "正在记录")
        case .processing: return String(localized: "正在整理")
        case .failed: return String(localized: "处理失败")
        case .ready: return String(localized: "已完成")
        }
    }

    private func headerBar(_ meeting: Meeting) -> some View {
        PageHeader {
            Breadcrumb(parent: String(localized: "会议"), title: meeting.title) { navigation.meeting = nil }
            LinearTabs(selection: Binding(get: { navigation.meetingTab }, set: { navigation.meetingTab = $0 }),
                       items: [.init(value: Tab.transcript, title: String(localized: "原始记录")),
                               .init(value: Tab.summary, title: String(localized: "AI 总结"))])
                .padding(.leading, 10)
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
                Button("删除录音，保留文字") { store.deleteRecording(id) }
                    .disabled(!meeting.hasRecording || processor.isProcessing(id))
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)]) }
                Divider()
                Button("删除会议…", role: .destructive) { confirmDelete = true }
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
                Button("对方 \(String(count)) 个人") { pendingRedo = .some(count) }
            }
        }
        .disabled(!canRedo)
    }

    @ViewBuilder
    private func banners(_ meeting: Meeting) -> some View {
        if let progress = processor.progress[id] {
            Callout(symbol: "circle.dotted", tint: Theme.Tint.progress) {
                Text(progress.stage).foregroundStyle(Theme.secondaryText)
                Spacer()
                ThinProgress(fraction: progress.fraction).frame(width: 160)
            }
        } else if meeting.state == .failed {
            let reason = meeting.processingError ?? ""
            Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.Tint.failed) {
                Text(String(localized: "会后整理失败，下面是会议中识别的文字：\(reason)")).foregroundStyle(Theme.text)
            }
        } else if !processor.diarizationReady, meeting.hasRecording {
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

/// 参会的人：头像和名字，点一下改名。
struct SpeakerBar: View {
    let meeting: Meeting
    let onRename: (String, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(meeting.activeSpeakers) { speaker in
                    RenameButton(speaker: speaker, onRename: onRename) {
                        HStack(spacing: 6) {
                            SpeakerAvatar(speaker: speaker, color: SpeakerColors.color(for: speaker.id, in: meeting), size: 18)
                            Text(speaker.name).font(Theme.small).foregroundStyle(Theme.text)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 9)
                        .frame(height: 24)
                        .background(Theme.subtle, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                }
            }
        }
    }
}

/// 没有下载说话人模型时的提示：下载后可以区分对方的多个人。
struct DiarizationModelBanner: View {
    let manager: ModelManager
    let onReady: () -> Void

    var body: some View {
        Callout(symbol: "person.3", tint: Theme.Tint.meeting) {
            switch manager.status {
            case .downloading(let fraction, _):
                Text("正在下载说话人模型 \(Int(fraction * 100))%").foregroundStyle(Theme.secondaryText)
                Spacer()
                ThinProgress(fraction: fraction).frame(width: 140)
            case .verifying:
                Text("正在校验…").foregroundStyle(Theme.secondaryText)
                Spacer()
                ThinProgress(fraction: nil).frame(width: 140)
            case .ready:
                Text("说话人模型已就绪").foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton("arrow.clockwise", help: "重新整理这场会议", size: 24, tint: Theme.Tint.meeting, action: onReady)
            default:
                Text(String(localized: "下载说话人模型（约 \(ByteCountFormatter.string(fromByteCount: manager.totalSize ?? 0, countStyle: .file))）后，可以区分对方的多个人"))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton("arrow.down.circle", help: "下载说话人模型", size: 24, tint: Theme.Tint.meeting) { manager.download() }
            }
        }
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
    var store: MeetingStore?
    var followLatest = false
    var actions: TranscriptActions?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(TranscriptGroup.make(meeting.segments)) { group in
                        TranscriptGroupView(meeting: meeting, group: group, player: player, store: store,
                                            actions: actions)
                            .id(group.id)
                    }
                }
                .frame(maxWidth: Theme.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
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
    let store: MeetingStore?
    let actions: TranscriptActions?

    private var speakers: [MeetingSpeaker] { group.speakerIDs.compactMap { meeting.speaker($0) } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarStack(meeting: meeting, speakers: speakers, size: 24)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(speakers) { speaker in
                        if let actions {
                            RenameButton(speaker: speaker, onRename: actions.rename) { name(speaker) }
                        } else {
                            name(speaker)
                        }
                    }
                    if group.speakerIDs.count > 1 {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.Tint.vocabulary).frame(width: 6, height: 6)
                            Text("同时在说")
                        }
                            .font(Theme.micro)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                            .help("几个人同时在说话，这段文字是混在一起识别出来的")
                    }
                    Text(TranscriptExport.clock(group.segments[0].start))
                        .font(Theme.small.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }
                ForEach(group.segments) { segment in
                    SegmentText(meeting: meeting, segment: segment, player: player, store: store, actions: actions)
                }
            }
        }
    }

    private func name(_ speaker: MeetingSpeaker) -> some View {
        Text(speaker.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
    }
}

/// 一段话：鼠标移上去时右边出现回放、编辑和更多操作（改说话人、拷贝、删除）。双击文字直接编辑。
struct SegmentText: View {
    let meeting: Meeting
    let segment: MeetingSegment
    let player: MeetingPlayer?
    let store: MeetingStore?
    let actions: TranscriptActions?
    @ViewState private var hovering = false
    @ViewState private var editing = false
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    private var playing: Bool { player?.playing == segment.id }

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
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { if actions != nil { startEditing() } }
                    tools
                        .opacity(hovering || playing ? 1 : 0)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(editing ? Theme.accent.opacity(0.07) : playing ? Theme.accent.opacity(0.1)
                    : hovering ? Theme.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radius))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .contextMenu { if actions != nil { menuItems } }
    }

    @ViewBuilder
    private var tools: some View {
        HStack(spacing: 2) {
            if let player, let store, player.canPlay(meeting) {
                Button {
                    player.toggle(segment, url: store.audioURL(meeting.id, segment.source))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 8, weight: .bold))
                        Text(TranscriptExport.clock(segment.start)).font(Theme.small.monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                }
                .buttonStyle(IconButtonStyle(tint: playing ? Theme.Tint.recording : Theme.accentText))
                .help("回放这一句")
            }
            if actions != nil {
                IconButton("pencil", help: "编辑这一句", size: 22, action: startEditing)
                IconMenu(symbol: "ellipsis", help: "更多", size: 22) { menuItems }
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
        if id == MeetingSpeaker.me.id { return Theme.accent }
        let others = meeting.speakers.filter { $0.id != MeetingSpeaker.me.id }
        let index = others.firstIndex { $0.id == id } ?? 0
        return palette[index % palette.count]
    }
}

/// 回放会议里的某一句：从这句的开始放到结束。
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var playing: Int?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func canPlay(_ meeting: Meeting) -> Bool {
        meeting.hasRecording && meeting.state != .recording && meeting.state != .processing
    }

    func toggle(_ segment: MeetingSegment, url: URL) {
        if playing == segment.id {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = segment.start
        player.play()
        self.player = player
        playing = segment.id
        let timer = Timer(timeInterval: max(0.5, segment.duration), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playing = nil
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
                EmptyState(symbol: "sparkles", tint: Theme.Tint.ai, title: String(localized: "正在生成总结…")) {
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
                    .frame(maxWidth: Theme.readableWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            } else {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = processor.summaryErrors[meeting.id] {
                Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.Tint.failed) {
                    Text(String(localized: "总结失败：\(error)")).foregroundStyle(Theme.text)
                }
                .frame(maxWidth: Theme.readableWidth)
                .padding(12)
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
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer()
            IconButton("pencil", help: "编辑总结", size: 26) {
                draft = summary.markdown
                editing = true
            }
            IconButton("doc.on.doc", help: "拷贝总结", size: 26) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.markdown, forType: .string)
            }
            IconButton("arrow.clockwise", help: "重新生成", size: 26, tint: Theme.Tint.ai) { processor.summarize(meeting.id) }
                .disabled(!config.isConfigured || meeting.segments.isEmpty)
            IconMenu(symbol: "ellipsis", help: "更多", size: 26) {
                Button("删除总结…", role: .destructive) { confirmDelete = true }
            }
        }
        .font(Theme.small)
        .padding(.top, 4)
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
                    .foregroundStyle(Theme.tertiaryText)
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
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        EmptyState(symbol: "sparkles", tint: Theme.Tint.ai, title: String(localized: "把这场会议整理成要点、决定和待办"),
                   message: config.isConfigured ? MeetingProcessor.destination(config)
                       : String(localized: "总结需要 AI 服务。可以用本机的 Ollama、LM Studio 或 Apple 智能，文字不会离开这台 Mac。")) {
            if config.isConfigured {
                RoundIconButton(symbol: "sparkles", help: "生成总结", tint: Theme.Tint.ai) { processor.summarize(meeting.id) }
                    .disabled(meeting.segments.isEmpty || processor.isProcessing(meeting.id))
            } else {
                RoundIconButton(symbol: "gearshape.fill", help: "配置 AI", tint: Theme.Tint.ai, size: 44, glyph: 0.42) {
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
        VStack(alignment: .leading, spacing: 10) {
            if !section.title.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(section.tint)
                        .frame(width: 22, height: 22)
                        .background(section.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(section.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
            MarkdownView(markdown: section.lines.joined(separator: "\n"))
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
            inline(text).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        } else if let rest = Self.strip(line, prefixes: ["- [ ] ", "* [ ] "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                inline(rest)
            }
        } else if let rest = Self.strip(line, prefixes: ["- [x] ", "- [X] ", "* [x] "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.Tint.done)
                inline(rest)
            }
        } else if let rest = Self.strip(line, prefixes: ["- ", "* ", "• "]) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.tertiaryText).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
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
