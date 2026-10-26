import SwiftUI
import TidytalkCore

/// 主窗口的「会议」页：所有会议按日期分组排成卡片，点一张进入这场会议（页头的「会议」可以返回）。
struct MeetingsView: View {
    let meetings: MeetingController
    let navigation: MainNavigation
    var onOpenSettings: (MainNavigation.SettingsPage) -> Void = { _ in }

    @ViewState private var renaming: Meeting?
    @ViewState private var newTitle = ""
    @ViewState private var deleting: Meeting?

    private var store: MeetingStore { meetings.store }

    var body: some View {
        Group {
            if let id = navigation.meeting {
                destination(id)
            } else {
                VStack(spacing: 0) {
                    header
                    gallery
                }
            }
        }
        .alert("重命名会议", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("会议标题", text: $newTitle)
            Button("好") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renaming?.id, !title.isEmpty { store.update(id) { $0.title = title } }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("删除这场会议？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { meeting in
            Button("删除会议和录音", role: .destructive) {
                if navigation.meeting == meeting.id { navigation.meeting = nil }
                store.delete(meeting.id)
            }
        } message: { meeting in
            Text("「\(meeting.title)」的文字、总结和录音都会删除，不能恢复。")
        }
    }

    private func rename(_ meeting: Meeting) {
        newTitle = meeting.title
        renaming = meeting
    }

    // MARK: - 页头和卡片

    private var header: some View {
        PageHeader {
            PageTitle(title: String(localized: "会议"))
        } trailing: {
            if !store.meetings.isEmpty {
                SearchField(text: Binding(get: { navigation.search }, set: { navigation.search = $0 }),
                            prompt: "搜索会议")
            }
            // 开始会议只放在会议页，而且同一时间只有一个按钮：还没有会议时在空白页中间，
            // 有会议以后在页头；正在录时下面是录制中的卡片
            if meetings.phase == .idle, !store.meetings.isEmpty || meetings.current != nil {
                IconButton("record.circle", help: "开始会议记录（⌃⌥M）", tint: Theme.Tint.recording, action: start)
            }
        }
    }

    private var filtered: [Meeting] {
        let query = navigation.search.trimmingCharacters(in: .whitespaces)
        let all = store.meetings.filter { $0.id != meetings.current?.id }
        guard !query.isEmpty else { return all }
        return all.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.speakers.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12, alignment: .top)]

    @ViewBuilder
    private var gallery: some View {
        if store.meetings.isEmpty && meetings.current == nil {
            MeetingEmptyView(meetings: meetings, onStart: start)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let live = meetings.current {
                        LiveMeetingCard(meeting: live, elapsed: meetings.elapsed) { navigation.meeting = live.id }
                    }
                    if filtered.isEmpty && !navigation.search.isEmpty {
                        EmptyState(symbol: "magnifyingglass", tint: Theme.Tint.meeting,
                                   title: String(localized: "没有找到“\(navigation.search)”"),
                                   message: String(localized: "会搜索会议标题、说话人和记录里的文字。"))
                            .frame(height: 280)
                    }
                    ForEach(MeetingFormat.groupedByDay(filtered), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: group.title, count: group.meetings.count)
                            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                                ForEach(group.meetings) { meeting in
                                    MeetingCard(meeting: meeting, progress: meetings.processor.progress[meeting.id],
                                                onOpen: { navigation.meeting = meeting.id },
                                                onRename: { rename(meeting) },
                                                onDelete: { deleting = meeting })
                                    .contextMenu {
                                        Button("打开") { navigation.meeting = meeting.id }
                                        Button("重命名…") { rename(meeting) }
                                        Divider()
                                        Button("删除会议…", role: .destructive) { deleting = meeting }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func destination(_ id: UUID) -> some View {
        if let live = meetings.current, live.id == id {
            MeetingLiveView(meetings: meetings, navigation: navigation)
        } else if store.meeting(id) != nil {
            MeetingDetailView(id: id, meetings: meetings, navigation: navigation, onOpenSettings: onOpenSettings)
        } else {
            VStack(spacing: 0) {
                PageHeader {
                    Breadcrumb(parent: String(localized: "会议"), title: String(localized: "会议已删除")) {
                        navigation.meeting = nil
                    }
                }
                EmptyState(symbol: "trash", tint: Theme.Tint.neutral, title: String(localized: "会议已删除"))
            }
        }
    }

    private func start() {
        meetings.start()
        if let id = meetings.current?.id { navigation.meeting = id }
    }
}

/// 一场会议的卡片：标题、时间、开头几句话、参会人头像，以及有没有总结、是否还在处理。
struct MeetingCard: View {
    let meeting: Meeting
    let progress: MeetingProcessor.Progress?
    let onOpen: () -> Void
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @ViewState private var hovering = false

    private var preview: String {
        meeting.segments.sorted { $0.start < $1.start }.prefix(3).map(\.text).joined(separator: " ")
    }

    /// 状态：处理中按进度填满，出错是红色，处理完是靛蓝的勾
    private var status: StatusIcon.Kind {
        switch meeting.state {
        case .recording: .recording
        case .processing: .progress(progress?.fraction)
        case .failed: .failed
        case .ready: progress != nil ? .progress(progress?.fraction) : .done
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 7) {
                    StatusIcon(kind: status, size: 13)
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if meeting.summary != nil {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Tint.ai)
                            .help("已生成 AI 总结")
                    }
                    Spacer(minLength: 8)
                }
                Text(preview.isEmpty ? String(localized: "没有识别到说话的内容") : preview)
                    .font(Theme.small)
                    .foregroundStyle(preview.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
                HStack(spacing: 8) {
                    AvatarStack(meeting: meeting, speakers: meeting.activeSpeakers, size: 18, limit: 5)
                    if let progress {
                        Text(progress.stage).lineLimit(1)
                            .font(Theme.small)
                            .foregroundStyle(Theme.Tint.progress)
                    } else if meeting.state == .failed {
                        Text("处理失败").font(Theme.small).foregroundStyle(Theme.Tint.failed)
                    }
                    Spacer()
                    Text("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(MeetingFormat.duration(meeting.duration))")
                        .font(Theme.small.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(hovering: hovering)
            .overlay(alignment: .topTrailing) {
                // 鼠标移上去时出现：重命名、删除
                IconMenu(symbol: "ellipsis", help: "更多", size: 24) {
                    Button("重命名…", action: onRename)
                    Divider()
                    Button("删除会议…", role: .destructive, action: onDelete)
                }
                .padding(6)
                .opacity(hovering ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 正在录的会议：排在最前面，点进去看实时文字。
struct LiveMeetingCard: View {
    let meeting: Meeting
    let elapsed: TimeInterval
    let onOpen: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                StatusIcon(kind: .recording, size: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在记录会议").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(meeting.segments.last?.text ?? String(localized: "开始说话后，文字会出现在这里。"))
                        .font(Theme.small)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(MeetingFormat.clock(elapsed))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle(hovering: hovering)
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: Theme.cardRadius, bottomLeadingRadius: Theme.cardRadius)
                    .fill(Theme.danger)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 还没有会议：说明会议记录怎么用。
struct MeetingEmptyView: View {
    let meetings: MeetingController
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "person.2.wave.2", tint: Theme.Tint.meeting, title: String(localized: "会议记录"),
                       message: String(localized: "同时录下你的麦克风和电脑里会议的声音，会后分出谁说了什么。")) {
                // 录音机那样的红色圆键
                RoundIconButton(symbol: "circle.fill", help: "开始会议记录（⌃⌥M）", tint: Theme.Tint.recording,
                                size: 52, glyph: 0.32, action: onStart)
                    .disabled(meetings.phase != .idle)
                KeyHint("⌃⌥M")
            }
            .frame(maxHeight: 340)
            VStack(alignment: .leading, spacing: 0) {
                feature("person.3", Theme.Tint.meeting, "对方有几个人也能分开", "几个人同时说话会标出来")
                divider
                feature("sparkles", Theme.Tint.ai, "会后可以生成 AI 总结", "要点、决定和待办")
                divider
                feature("lock", Theme.Tint.local, "只保存在这台 Mac 上", "录音和文字可以随时删除")
            }
            .cardStyle()
            .frame(maxWidth: 420)
            Text("也可以在菜单栏菜单里开始")
                .font(Theme.small)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 30)
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 48)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey,
                         _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).font(Theme.small).foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// 正在录的会议：顶部是计时和两路电平，下面是实时文字（"我"和"对方"两种颜色）。
struct MeetingLiveView: View {
    let meetings: MeetingController
    let navigation: MainNavigation

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                Breadcrumb(parent: String(localized: "会议"), title: String(localized: "正在记录")) {
                    navigation.meeting = nil
                }
            } trailing: {
                IconButton("stop.fill", help: "结束会议（⌃⌥M）", tint: Theme.Tint.recording, prominent: true) {
                    meetings.stop()
                }
                .disabled(meetings.phase != .recording)
            }
            status
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 4)
            if let meeting = meetings.current {
                if meeting.segments.isEmpty {
                    EmptyState(symbol: "waveform", tint: Theme.Tint.recording, title: String(localized: "正在听"),
                               message: String(localized: "开始说话后，文字会出现在这里。说完一句才显示，会后还会分说话人、精修一遍。"))
                } else {
                    TranscriptList(meeting: meeting, followLatest: true)
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                StatusIcon(kind: .recording, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingFormat.clock(meetings.elapsed))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    Text(meetings.phase == .finishing ? String(localized: "正在识别最后几句…") : String(localized: "正在记录会议"))
                        .font(Theme.small)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    // 我：麦克风的颜色；对方：会议的颜色
                    MeetingLevelMeter(label: String(localized: "我"), level: meetings.levels[.microphone] ?? 0,
                                      color: Theme.Tint.dictation)
                    MeetingLevelMeter(label: String(localized: "对方"), level: meetings.levels[.system] ?? 0,
                                      color: Theme.Tint.meeting)
                }
            }
            .padding(14)
            .cardStyle()
            if let warning = meetings.warning {
                Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.warning) {
                    Text(warning).foregroundStyle(Theme.text)
                }
            }
        }
    }
}

/// 一路声音的电平：几根随音量跳动的竖条。
struct MeetingLevelMeter: View {
    let label: String
    let level: Float
    var color: Color = .green

    private static let bars = 8

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.small).foregroundStyle(Theme.secondaryText)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    let lit = Float(index) / Float(Self.bars) < level
                    Capsule()
                        .fill(lit ? color : Theme.selected)
                        .frame(width: 3, height: 6 + CGFloat(index % 4) * 2.5)
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}

/// 正在录音的红点，慢慢闪动。
struct RecordingDot: View {
    var size: CGFloat = 8
    @ViewState private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

enum MeetingFormat {
    /// 1:02:03 或 12:34
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "45 分钟"、"1 小时 5 分钟"、"不到 1 分钟"
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "不到 1 分钟") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? ""
    }

    /// 按天分组：今天、昨天、其他日期（"10月21日 星期二"），每组里从新到旧。
    static func groupedByDay(_ meetings: [Meeting]) -> [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var groups: [(title: String, meetings: [Meeting])] = []
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            let title: String
            if calendar.isDateInToday(meeting.startedAt) {
                title = String(localized: "今天")
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                title = String(localized: "昨天")
            } else {
                title = meeting.startedAt.formatted(.dateTime.month().day().weekday())
            }
            if groups.last?.title == title {
                groups[groups.count - 1].meetings.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        return groups
    }
}
