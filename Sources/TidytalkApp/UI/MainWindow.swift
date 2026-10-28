import AppKit
import Observation
import SwiftUI
import TidytalkCore

/// 主窗口里现在显示哪一页、选中了哪场会议。菜单栏菜单、快捷键打开主窗口时用它跳到对应的页。
@MainActor
@Observable
final class MainNavigation {
    enum Section: String, CaseIterable, Identifiable {
        case meetings, transcribe, history, vocabulary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .meetings: String(localized: "会议")
            case .transcribe: String(localized: "转写")
            case .history: String(localized: "最近记录")
            case .vocabulary: String(localized: "词库")
            }
        }

        /// 侧边栏图标：和 Linear 一样是单色的线条图标。
        var symbol: String {
            switch self {
            case .meetings: "person.2"
            case .transcribe: "waveform"
            case .history: "clock"
            case .vocabulary: "character.book.closed"
            }
        }

        /// 功能色（见 `Theme.Tint`）
        var color: Color {
            switch self {
            case .meetings: Theme.Tint.meeting
            case .transcribe: Theme.Tint.speech
            case .history: Theme.Tint.history
            case .vocabulary: Theme.Tint.vocabulary
            }
        }
    }

    /// 设置的各页，顺序和设置侧边栏一致。词库不在这里：主窗口本来就有「词库」页。
    enum SettingsPage: Int, CaseIterable, Identifiable {
        case general = 0, dictation, models, ai, captions, meeting

        var id: Int { rawValue }
    }

    /// 转写页的两个标签：本机文件、网上的链接。
    enum TranscribeTab: Hashable { case file, link }

    var section: Section = .meetings
    var meeting: UUID?
    /// 会议详情看的是原始记录还是 AI 总结；换一场会议时保持不变。
    var meetingTab: MeetingDetailView.Tab = .transcript
    /// 会议列表的搜索词。
    var search = ""

    var transcription: UUID?
    var transcribeTab: TranscribeTab = .file
    var transcribeSearch = ""

    /// 正在看的设置页；nil 表示在看会议、转写这些页。设置和这些页在同一个窗口里（和 Linear 一样），
    /// 打开设置时侧边栏换成设置的各页。
    private(set) var settings: SettingsPage?
    /// 上次看的设置页：再打开设置（⌘,）时回到这一页。
    private(set) var lastSettingsPage: SettingsPage = .general

    func openSettings(_ page: SettingsPage? = nil) {
        let page = page ?? lastSettingsPage
        settings = page
        lastSettingsPage = page
    }

    func closeSettings() {
        settings = nil
    }

    /// 回到某一页（从设置里按 ⌘1–⌘4、菜单栏菜单打开转写页时）。
    func show(_ section: Section) {
        settings = nil
        self.section = section
    }
}

/// 设置里几处要由应用处理的操作（打开引导、开关字幕……）。
struct SettingsActions {
    var onOpenOnboarding: () -> Void = {}
    var onToggleListening: () -> Void = {}
    var onListenSourceChanged: () -> Void = {}
    var onSetCaptionTranslation: (Bool) -> Void = { _ in }
}

/// 主窗口：左边是功能列表，右边是对应的页面。设置也在这个窗口里：点左下角的「设置」（或 ⌘,），
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
                SettingsContent(page: page, model: model, meetingStore: meetings.store, actions: settingsActions)
            } else {
                detail
            }
        }
        .frame(minWidth: 900, minHeight: 580)
    }

    private var sidebar: some View {
            VStack(alignment: .leading, spacing: 1) {
                SidebarBrand().padding(.bottom, 10)
                ForEach(Array(MainNavigation.Section.allCases.enumerated()), id: \.element) { index, section in
                    SidebarRow(symbol: section.symbol, title: section.title, tint: section.color, count: count(section),
                               trailing: "⌘\(index + 1)", selected: navigation.section == section) {
                        select(section)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Spacer()
                // 设置放在菜单最下面，点了侧边栏换成设置的各页
                SidebarRow(symbol: "gearshape", title: String(localized: "设置"), trailing: "⌘,", selected: false) {
                    navigation.openSettings()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }

    /// 再点一次当前的页回到列表（和 Linear 一样）。
    private func select(_ section: MainNavigation.Section) {
        if navigation.section == section {
            switch section {
            case .meetings: navigation.meeting = nil
            case .transcribe: navigation.transcription = nil
            default: break
            }
        }
        navigation.section = section
    }

    private func count(_ section: MainNavigation.Section) -> Int? {
        switch section {
        case .meetings: meetings.store.meetings.count
        case .transcribe: transcriber.store.items.count
        case .history: model.configStore.config.history ? model.history.count : nil
        case .vocabulary: nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .meetings:
            MeetingsView(meetings: meetings, navigation: navigation, onOpenSettings: onOpenSettings)
        case .transcribe:
            TranscribeView(controller: transcriber, navigation: navigation)
        case .history:
            HistoryView(model: model, onOpenSettings: onOpenSettings)
        case .vocabulary:
            VStack(spacing: 0) {
                PageHeader { PageTitle(title: String(localized: "词库")) }
                VocabularySettings(model: model)
                    .scrollContentBackground(.hidden)
            }
        }
    }
}

/// 「最近记录」：最近 20 次说话输入的结果，只保存在内存里。
struct HistoryView: View {
    let model: AppModel
    var onOpenSettings: (MainNavigation.SettingsPage) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(title: String(localized: "最近记录"))
            } trailing: {
                if model.configStore.config.history, !model.history.isEmpty {
                    Text("只保存在内存里，退出后清空").font(Theme.small).foregroundStyle(Theme.tertiaryText)
                    IconButton("trash", help: "清空记录", destructive: true) { model.clearHistory() }
                }
            }
            if !model.configStore.config.history {
                EmptyState(symbol: "clock.badge.xmark", tint: Theme.Tint.history,
                           title: String(localized: "已在设置里关闭最近记录"),
                           message: String(localized: "打开后，最近 20 次说话输入的结果会显示在这里。")) {
                    RoundIconButton(symbol: "gearshape.fill", help: "打开设置", tint: Theme.Tint.neutral, size: 44, glyph: 0.42) {
                        onOpenSettings(.general)
                    }
                }
            } else if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", tint: Theme.Tint.history,
                           title: String(localized: "还没有说话输入的记录"),
                           message: String(localized: "最近 20 次的结果会显示在这里，只保存在内存里，退出 Tidytalk 后清空。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry)
                            Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// 最近记录的一行：类型图标、结果文字、时间，鼠标移上去出现拷贝。
struct HistoryRow: View {
    let entry: HistoryEntry
    @ViewState private var hovering = false

    private var symbol: String {
        switch entry.kind {
        case .dictation: "mic.fill"
        case .rewrite: "wand.and.sparkles"
        case .snippet: "text.badge.plus"
        }
    }

    /// 说话输入红色（麦克风），语音改写紫色（AI），快捷短语橙色（在词库里设置）
    private var color: Color {
        switch entry.kind {
        case .dictation: Theme.Tint.dictation
        case .rewrite: Theme.Tint.ai
        case .snippet: Theme.Tint.vocabulary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.output)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(3)
                switch entry.kind {
                case .rewrite: Text("语音改写").font(Theme.small).foregroundStyle(Theme.Tint.ai)
                case .snippet: Text("快捷短语").font(Theme.small).foregroundStyle(Theme.Tint.vocabulary)
                case .dictation: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if entry.transcript != entry.output {
                    IconMenu(symbol: "ellipsis", help: "更多", size: 24) {
                        Button("拷贝") { copy(entry.output) }
                        Button("拷贝识别原文") { copy(entry.transcript) }
                    }
                }
                IconButton("doc.on.doc", help: "拷贝", size: 24) { copy(entry.output) }
            }
            .opacity(hovering ? 1 : 0)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(Theme.small.monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
                .frame(minWidth: 44, alignment: .trailing)
                .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? Theme.hover : .clear)
        .onHover { hovering = $0 }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.setFrameAutosaveName("TidytalkMainWindow")
        if !window.setFrameUsingName("TidytalkMainWindow") { window.center() }
        return window
    }
}
