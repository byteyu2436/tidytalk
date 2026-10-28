import AppKit
import Observation
import SwiftUI
import TidytalkCore

/// 主窗口里现在显示哪一页、打开了哪条记录。菜单栏菜单、快捷键打开主窗口时用它跳到对应的页。
@MainActor
@Observable
final class MainNavigation {
    /// 侧边栏的四页：首页（今天的情况和三个功能的入口）、转写（转写文件和链接）、
    /// 资料库（说话、会议、转写的结果都在这里）、词库。
    enum Section: String, CaseIterable, Identifiable {
        case home, transcribe, library, vocabulary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: String(localized: "首页")
            case .transcribe: String(localized: "转写")
            case .library: String(localized: "资料库")
            case .vocabulary: String(localized: "词库")
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .transcribe: "waveform"
            case .library: "books.vertical"
            case .vocabulary: "character.book.closed"
            }
        }

        /// 功能色（见 `Theme.Tint`）
        var color: Color {
            switch self {
            case .home: Theme.text
            case .transcribe: Theme.Tint.speech
            case .library: Theme.Tint.meeting
            case .vocabulary: Theme.Tint.vocabulary
            }
        }
    }

    /// 资料库按类型筛选。
    enum LibraryFilter: String, CaseIterable, Hashable {
        case all, dictation, meetings, transcriptions
    }

    /// 设置的各页，顺序和设置侧边栏一致（功能、共用、系统三组）。
    enum SettingsPage: Int, CaseIterable, Identifiable {
        case dictation = 0, captions, meeting, shortcuts, ai, models, general, privacy, about

        var id: Int { rawValue }
    }

    var section: Section = .home

    var libraryFilter: LibraryFilter = .all
    /// 资料库最新的在前（false 时最早的在前）
    var newestFirst = true
    /// 资料库的搜索词
    var search = ""

    /// 打开的那条记录（同一时间只有一个不为 nil）。记录在哪一页打开，侧边栏就选中哪一页，
    /// 页头写“那一页 › 标题”，返回时回到那一页。
    var meeting: UUID?
    /// 会议详情看的是原始记录还是 AI 总结；换一场会议时保持不变。
    var meetingTab: MeetingDetailView.Tab = .transcript
    var transcription: UUID?
    var dictation: UUID?

    /// 词库看的是哪个标签
    var vocabularyTab: VocabularyView.Tab = .terms

    /// 每加一，转写页的链接输入框就获得一次焦点（菜单"转写链接…"）。
    var linkFieldRequest = 0
    /// 每加一，资料库的搜索框就获得一次焦点（⌘F）。
    var searchRequest = 0
    /// 每加一，正在看的会议或转写弹出一次导出面板（文件 › 导出… ⇧⌘E）。
    var exportRequest = 0

    /// 正在看的设置页；nil 表示在看首页、资料库这些页。设置和这些页在同一个窗口里，
    /// 打开设置时侧边栏换成设置的各页。
    private(set) var settings: SettingsPage?
    /// 上次看的设置页：再打开设置（⌘,）时回到这一页。
    private(set) var lastSettingsPage: SettingsPage = .dictation

    func openSettings(_ page: SettingsPage? = nil) {
        let page = page ?? lastSettingsPage
        settings = page
        lastSettingsPage = page
    }

    func closeSettings() {
        settings = nil
    }

    /// 回到某一页的列表（侧边栏、⌘1–⌘4、菜单栏菜单打开主窗口时）。
    func show(_ section: Section) {
        settings = nil
        closeRecord()
        self.section = section
    }

    /// 开着的会议、转写或说话记录（详情页）。
    var hasRecord: Bool { meeting != nil || transcription != nil || dictation != nil }

    func openMeeting(_ id: UUID) {
        show(.library)
        meeting = id
    }

    /// 转写记录可以从“转写”页或资料库打开。
    func openTranscription(_ id: UUID, from section: Section = .transcribe) {
        show(section)
        transcription = id
    }

    func openDictation(_ id: UUID) {
        show(.library)
        dictation = id
    }

    /// 回到这一页的列表。
    func closeRecord() {
        meeting = nil
        transcription = nil
        dictation = nil
    }
}

/// 主窗口里几处要由应用处理的操作（打开引导、开关字幕、重新整理……）。
struct SettingsActions {
    var onOpenOnboarding: () -> Void = {}
    var onToggleListening: () -> Void = {}
    var onListenSourceChanged: () -> Void = {}
    var onSetCaptionTranslation: (Bool) -> Void = { _ in }
    var onReprocess: (HistoryEntry, CleanupStyle, OutputLanguage) -> Void = { _, _, _ in }
}

/// 主窗口：左边是首页、转写、资料库、词库，右边是对应的页面。设置也在这个窗口里：点左下角的「设置」（或 ⌘,），
/// 侧边栏换成设置的各页，「‹ 设置」或 ⌘[ 回来。
struct MainView: View {
    let model: AppModel
    let meetings: MeetingController
    let transcriber: TranscribeController
    let navigation: MainNavigation
    var settingsActions = SettingsActions()

    private var onOpenSettings: (MainNavigation.SettingsPage) -> Void {
        { [navigation] page in navigation.openSettings(page) }
    }

    var body: some View {
        AppShell {
            if navigation.settings != nil {
                SettingsSidebar(navigation: navigation)
            } else {
                sidebar
            }
        } content: {
            if let page = navigation.settings {
                SettingsContent(page: page, model: model, meetingStore: meetings.store,
                                transcriptionStore: transcriber.store, actions: settingsActions,
                                onOpenPage: onOpenSettings)
            } else {
                detail
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // 设计稿的 App Sidebar：应用名、四页、底部的状态卡片和设置
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarBrand()
            ForEach(Array(MainNavigation.Section.allCases.enumerated()), id: \.element) { index, section in
                SidebarRow(symbol: section.symbol, title: section.title, tint: section.color, count: count(section),
                           trailing: "⌘\(index + 1)", selected: navigation.section == section) {
                    navigation.show(section)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Spacer()
            SidebarStatusCard(model: model, meetings: meetings, navigation: navigation, actions: settingsActions)
            Spacer().frame(height: 6)
            // 设置放在最下面，点了侧边栏换成设置的各页
            SidebarRow(symbol: "gearshape", title: String(localized: "设置"), tint: Theme.secondaryText, trailing: "⌘,",
                       selected: false) {
                navigation.openSettings()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func count(_ section: MainNavigation.Section) -> Int? {
        guard section == .library else { return nil }
        return model.history.count + meetings.store.meetings.count + transcriber.store.items.count
    }

    @ViewBuilder
    private var detail: some View {
        if let id = navigation.meeting {
            meetingDestination(id)
        } else if let id = navigation.transcription {
            TranscriptionDetailView(id: id, controller: transcriber, navigation: navigation)
        } else if let id = navigation.dictation {
            DictationDetailView(id: id, model: model, navigation: navigation, actions: settingsActions)
        } else {
            switch navigation.section {
            case .home:
                HomeView(model: model, meetings: meetings, transcriber: transcriber, navigation: navigation,
                         actions: settingsActions)
            case .transcribe:
                TranscribeView(transcriber: transcriber, navigation: navigation)
            case .library:
                LibraryView(model: model, meetings: meetings, transcriber: transcriber, navigation: navigation,
                            actions: settingsActions, onOpenSettings: onOpenSettings)
            case .vocabulary:
                VocabularyView(model: model, navigation: navigation)
            }
        }
    }

    @ViewBuilder
    private func meetingDestination(_ id: UUID) -> some View {
        if let live = meetings.current, live.id == id {
            MeetingLiveView(meetings: meetings, navigation: navigation)
        } else if meetings.store.meeting(id) != nil {
            MeetingDetailView(id: id, meetings: meetings, navigation: navigation, onOpenSettings: onOpenSettings)
        } else {
            RecordGoneView(navigation: navigation)
        }
    }
}

/// 正在看的记录被删掉了（在别处删除、过了保留时间）：页头写“记录已删除”，中间是空状态。
struct RecordGoneView: View {
    let navigation: MainNavigation

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                Breadcrumb(parent: navigation.section.title, title: String(localized: "记录已删除")) {
                    navigation.closeRecord()
                }
            }
            EmptyState(symbol: "trash", title: String(localized: "这条记录已经删除"),
                       message: String(localized: "可能在别处删掉了，或者超过了保留时间。"))
                .padding(.bottom, 60)
        }
    }
}

/// 侧边栏底部的卡片（高 68）：正在记录会议、正在收听字幕时显示计时和停止按钮——整个窗口只有这一个停止按钮；
/// 平时显示说话输入是否就绪，还没准备好时是黄点。
struct SidebarStatusCard: View {
    let model: AppModel
    let meetings: MeetingController
    let navigation: MainNavigation
    let actions: SettingsActions

    var body: some View {
        if let live = meetings.current, meetings.phase != .idle {
            card(border: Theme.Tint.recording) {
                RecordingDot(size: 8)
                text(String(localized: "正在记录会议"), "\(MeetingFormat.clock(meetings.elapsed)) · ⌃⌥M 结束")
                IconButton("square", help: "结束会议（⌃⌥M）", size: 28, tint: Theme.Tint.recording,
                           prominent: true) { meetings.stop() }
                    .disabled(meetings.phase != .recording)
            }
            .onTapGesture { navigation.openMeeting(live.id) }
        } else if model.isListening {
            card(border: Theme.Tint.captions) {
                Circle().fill(Theme.Tint.captions).frame(width: 8, height: 8)
                text(String(localized: "正在收听电脑声音"), listeningDetail)
                IconButton("square", help: "停止收听（⌃⌥C）", size: 28, tint: Theme.Tint.captions, outlined: true,
                           action: actions.onToggleListening)
            }
        } else {
            let ready = model.readiness == .ready
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(ready ? Theme.Tint.local : Theme.Tint.progress).frame(width: 8, height: 8)
                    Text(ready ? String(localized: "\(model.configStore.config.speechModel.title) 已就绪")
                         : String(localized: "还不能说话输入"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if ready {
                        Text("按住").font(Theme.small).foregroundStyle(Theme.secondaryText)
                        KeyHint(model.configStore.config.hotkey.symbol)
                        Text("说话，松开出字").font(Theme.small).foregroundStyle(Theme.secondaryText)
                    } else {
                        Text(Readiness.short(model)).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(Theme.border))
            .contentShape(Rectangle())
            .onTapGesture { if !ready { navigation.show(.home) } }
        }
    }

    /// 中文 → 英文 · ⌃⌥C 停止
    private var listeningDetail: String {
        let config = model.configStore.config
        guard config.captionTranslate else { return String(localized: "⌃⌥C 停止") }
        return String(localized: "译成\(config.captionLanguage.title) · ⌃⌥C 停止")
    }

    private func card<Content: View>(border: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).strokeBorder(border))
            .contentShape(Rectangle())
    }

    private func text(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(subtitle).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 还没准备好时，首页提示条和侧边栏卡片上的写法（设计稿「首页 · 还没准备好」）。
@MainActor
enum Readiness {
    /// 提示条的标题和说明
    static func alert(_ model: AppModel) -> (title: String, message: String)? {
        switch model.readiness {
        case .ready: return nil
        case .needsMicrophone:
            return (String(localized: "还差一步：允许使用麦克风"),
                    String(localized: "说话输入和会议记录要用麦克风录音。在系统设置里打开后回到这里，不用重新启动。"))
        case .needsAccessibility:
            return (String(localized: "还差一步：允许“辅助功能”"),
                    String(localized: "说话输入要用它监听快捷键、把文字粘贴到光标处。在系统设置里打开后回到这里，不用重新启动。"))
        case .modelNotReady:
            if case .downloading(let fraction, _) = model.models.status {
                return (String(localized: "正在下载语音识别模型 \(Int(fraction * 100))%"),
                        String(localized: "下载完就能说话输入，可以先去做别的。"))
            }
            return (String(localized: "还差一步：下载语音识别模型"),
                    String(localized: "声音在这台 Mac 上识别，要先下载一个识别模型。"))
        }
    }

    /// 侧边栏卡片的第二行
    static func short(_ model: AppModel) -> String {
        switch model.readiness {
        case .ready: ""
        case .needsMicrophone: String(localized: "麦克风没有打开")
        case .needsAccessibility: String(localized: "辅助功能没有打开")
        case .modelNotReady:
            if case .downloading(let fraction, _) = model.models.status {
                String(localized: "正在下载识别模型 \(Int(fraction * 100))%")
            } else {
                String(localized: "识别模型还没下载")
            }
        }
    }
}

enum MainWindow {
    @MainActor
    static func make(model: AppModel, meetings: MeetingController, transcriber: TranscribeController,
                     navigation: MainNavigation, settings: SettingsActions = SettingsActions()) -> NSWindow {
        let view = MainView(model: model, meetings: meetings, transcriber: transcriber, navigation: navigation,
                            settingsActions: settings)
        let window = FocusFriendlyWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        AppShell<EmptyView, EmptyView>.configure(window, title: "Tidytalk")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.setFrameAutosaveName("TidytalkMainWindow")
        if !window.setFrameUsingName("TidytalkMainWindow") { window.center() }
        return window
    }
}
