import AppKit
import SwiftUI
import TidytalkCore

/// 「首页」（设计稿「主窗口 · 首页」）：今天的情况、三个功能的入口（说话输入、实时字幕、会议记录）和最近的记录。
/// 开始按钮在卡片上，停止按钮只在侧边栏底部的卡片上。转写在自己的页面里。
struct HomeView: View {
    let model: AppModel
    let meetings: MeetingController
    let transcriber: TranscribeController
    let navigation: MainNavigation
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(title: String(localized: "首页"))
            } trailing: {
                SearchField(text: Binding(get: { navigation.search }, set: { navigation.search = $0 }),
                            prompt: "搜索资料库")
                    .onSubmit { navigation.show(.library) }
            }
            PageBody {
                if let alert = Readiness.alert(model) {
                    AlertBar(symbol: "exclamationmark.triangle", tint: Theme.Tint.progress, title: alert.title,
                             message: alert.message) {
                        IconButton("arrow.up.right", help: model.readiness == .modelNotReady ? "打开识别模型设置" : "打开系统设置",
                                   outlined: true, action: fixReadiness)
                    }
                }
                greeting
                cards
                recent
            }
        }
    }

    private func fixReadiness() {
        switch model.readiness {
        case .needsMicrophone: Permissions.openMicrophoneSettings()
        case .needsAccessibility: Permissions.openAccessibilitySettings()
        case .modelNotReady: navigation.openSettings(.models)
        case .ready: break
        }
    }

    // MARK: - 问候和今天的用量

    private var isFirstUse: Bool {
        model.history.isEmpty && meetings.store.meetings.isEmpty && transcriber.store.items.isEmpty
    }

    private var greeting: some View {
        PageHeading(title: isFirstUse ? String(localized: "你好，欢迎使用 Tidytalk") : Self.greeting(for: Date()),
                    message: isFirstUse
                        ? String(localized: "下面三件事都在这台 Mac 上完成。说过的话、开过的会和转写的结果都会放进资料库。")
                        : today)
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: String(localized: "早上好")
        case 11..<13: String(localized: "中午好")
        case 13..<18: String(localized: "下午好")
        default: String(localized: "晚上好")
        }
    }

    /// 今天说了多少字、大约省下多少分钟打字（按打字每分钟 50 字、说话每分钟 200 字估算）、开了几场会。
    private var today: String {
        let calendar = Calendar.current
        let words = model.history.filter { $0.kind == .dictation && calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.output.count }
        let meetingCount = meetings.store.meetings.filter { calendar.isDateInToday($0.startedAt) }.count
        var parts: [String] = []
        if words > 0 {
            let saved = Int((Double(words) / 50 - Double(words) / 200).rounded())
            parts.append(saved >= 1
                         ? String(localized: "今天说了 \(words.formatted()) 字，大约省下 \(String(saved)) 分钟打字")
                         : String(localized: "今天说了 \(words.formatted()) 字"))
        }
        if meetingCount > 0 { parts.append(String(localized: "开了 \(String(meetingCount)) 场会")) }
        if parts.isEmpty {
            return String(localized: "今天还没开始。在任何输入框里按住 \(model.configStore.config.hotkey.symbol) 说话试试。")
        }
        return parts.joined(separator: String(localized: "；")) + String(localized: "。")
    }

    // MARK: - 三个功能

    private var cards: some View {
        HStack(spacing: 12) {
            FeatureCard(symbol: "mic", tint: Theme.Tint.dictation, title: String(localized: "说话输入"),
                        message: String(localized: "在任何输入框里按住快捷键说话，松开就是整理好的文字。"),
                        keys: model.configStore.config.hotkey.symbol) {
                Text("按住说话").font(Theme.small).foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 4)
                if model.readiness == .ready {
                    StatusDot(color: Theme.Tint.local, text: String(localized: "已就绪"))
                } else {
                    StatusDot(color: Theme.Tint.progress, text: model.readiness == .modelNotReady
                              ? String(localized: "缺少模型") : String(localized: "缺少权限"))
                }
            }
            FeatureCard(symbol: "captions.bubble", tint: Theme.Tint.captions, title: String(localized: "实时字幕"),
                        message: String(localized: "把电脑里正在播放的声音变成字幕，可以边听边翻译。"), keys: "⌃⌥C") {
                Spacer(minLength: 4)
                if model.isListening {
                    StatusDot(color: Theme.Tint.captions, text: String(localized: "正在收听"))
                } else {
                    IconButton("play", help: "开始收听（⌃⌥C）", tint: Theme.Tint.captions, outlined: true,
                               action: actions.onToggleListening)
                }
            }
            FeatureCard(symbol: "person.2", tint: Theme.Tint.meeting, title: String(localized: "会议记录"),
                        message: String(localized: "同时录下你和对方的声音，会后分出说话人、生成总结。"), keys: "⌃⌥M") {
                Spacer(minLength: 4)
                if let live = meetings.current, meetings.phase != .idle {
                    StatusDot(color: Theme.Tint.recording,
                              text: String(localized: "正在记录 \(MeetingFormat.clock(meetings.elapsed))"))
                    IconButton("arrow.right", help: "打开正在记录的会议", outlined: true) { navigation.openMeeting(live.id) }
                } else {
                    IconButton("circle", help: "开始会议记录（⌃⌥M）", tint: Theme.Tint.recording, prominent: true) {
                        meetings.start()
                        if let id = meetings.current?.id { navigation.openMeeting(id) }
                    }
                }
            }
        }
        .frame(height: 192)
    }

    // MARK: - 最近

    private var recentItems: [LibraryItem] {
        let all = model.history.map(LibraryItem.dictation)
            + meetings.store.meetings.map(LibraryItem.meeting)
            + transcriber.store.items.map(LibraryItem.transcription)
        // 上面有提示条时少放一条，免得要滚动
        return Array(all.sorted { $0.date > $1.date }.prefix(Readiness.alert(model) == nil ? 4 : 3))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: Theme.titleGap) {
            GroupTitle(title: String(localized: "最近")) {
                if !recentItems.isEmpty {
                    IconButton("arrow.right", help: "打开资料库") { navigation.show(.library) }
                }
            }
            if recentItems.isEmpty {
                EmptyState(symbol: "mic", tint: Theme.Tint.dictation, title: String(localized: "还没有记录"),
                           message: String(localized: "按住 \(model.configStore.config.hotkey.symbol) 在任何输入框里说一句话，结果会出现在这里。"),
                           fill: false)
                    .padding(.vertical, -8)
                    .cardStyle()
            } else {
                RowList(recentItems) { item in
                    LibraryRow(item: item, status: status(item)) { open(item) }
                }
            }
        }
    }

    private func status(_ item: LibraryItem) -> RowStatus? {
        switch item {
        case .dictation: nil
        case .meeting(let meeting): RowStatus.meeting(meeting, processor: meetings.processor)
        case .transcription(let transcription): RowStatus.transcription(transcription, controller: transcriber)
        }
    }

    private func open(_ item: LibraryItem) {
        switch item {
        case .dictation(let entry): navigation.openDictation(entry.id)
        case .meeting(let meeting): navigation.openMeeting(meeting.id)
        case .transcription(let transcription): navigation.openTranscription(transcription.id, from: .library)
        }
    }
}

/// 状态小圆点和一句话：已就绪、缺少权限、正在收听、正在记录 12:34。
struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
    }
}

/// 首页的一张功能卡（高 192，内边距 20）：图标、名字、一句说明，最下面是快捷键和开始按钮。
struct FeatureCard<Bottom: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let keys: String
    @ViewBuilder let bottom: () -> Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.heading).foregroundStyle(Theme.text)
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                KeyHint(keys)
                bottom()
            }
            .frame(height: 32)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle()
    }
}
