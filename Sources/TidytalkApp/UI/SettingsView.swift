import AppKit
import Observation
import SwiftUI
import TidytalkCore

extension MainNavigation.SettingsPage {
    /// 设置侧边栏的三组：只属于一个功能的、几个功能共用的、和 Tidytalk 本身有关的。
    enum Group: CaseIterable {
        case features, shared, system

        var title: String {
            switch self {
            case .features: String(localized: "功能")
            case .shared: String(localized: "共用")
            case .system: String(localized: "系统")
            }
        }

        var pages: [MainNavigation.SettingsPage] {
            switch self {
            case .features: [.dictation, .captions, .meeting]
            case .shared: [.shortcuts, .ai, .models]
            case .system: [.general, .privacy, .about]
            }
        }
    }

    var title: String {
        switch self {
        case .dictation: String(localized: "说话输入")
        case .captions: String(localized: "实时字幕")
        case .meeting: String(localized: "会议记录")
        case .shortcuts: String(localized: "快捷键")
        case .ai: String(localized: "AI 服务")
        case .models: String(localized: "识别模型")
        case .general: String(localized: "通用")
        case .privacy: String(localized: "隐私与数据")
        case .about: String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .captions: "captions.bubble"
        case .meeting: "person.2"
        case .shortcuts: "keyboard"
        case .ai: "sparkles"
        case .models: "waveform"
        case .general: "gearshape"
        case .privacy: "checkmark.shield"
        case .about: "info.circle"
        }
    }

    /// 功能色：和主窗口、首页里同一个功能的颜色一样
    var color: Color {
        switch self {
        case .dictation: Theme.Tint.dictation
        case .captions: Theme.Tint.captions
        case .meeting: Theme.Tint.meeting
        case .shortcuts: Theme.text
        case .ai: Theme.Tint.ai
        case .models: Theme.Tint.speech
        case .general, .about: Theme.Tint.neutral
        case .privacy: Theme.Tint.local
        }
    }
}

/// 打开设置后主窗口的侧边栏：最上面「‹ 设置」回到原来的页，下面是分成三组的设置页。
struct SettingsSidebar: View {
    let navigation: MainNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsBackRow { navigation.closeSettings() }
            ForEach(MainNavigation.SettingsPage.Group.allCases, id: \.self) { group in
                Text(group.title)
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(group.pages) { page in
                    SidebarRow(symbol: page.symbol, title: page.title, tint: page.color,
                               selected: navigation.settings == page) {
                        navigation.openSettings(page)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background {
            // 在设置里按 ⌘1–⌘3 也直接回到对应的页
            ForEach(Array(MainNavigation.Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigation.show(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 「‹ 设置」：点一下（或 ⌘[）回到打开设置前的页。
private struct SettingsBackRow: View {
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                    .frame(width: 16)
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                KeyHint("⌘[")
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help("返回（⌘[）")
    }
}

/// 打开设置后主窗口右边的内容：当前这一页的设置。
struct SettingsContent: View {
    let page: MainNavigation.SettingsPage
    let model: AppModel
    let meetingStore: MeetingStore
    var transcriptionStore: TranscriptionStore?
    let actions: SettingsActions
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                Text("设置").font(Theme.body).foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                PageTitle(title: page.title)
            }
            content
                .id(page)
        }
        .onChange(of: page) {
            // 切换页时不自动聚焦输入框
            (NSApp.keyWindow as? FocusFriendlyWindow)?.clearFocusSoon()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .dictation: DictationSettings(model: model, onOpenPage: onOpenPage)
        case .captions:
            CaptionSettings(model: model, onSourceChanged: actions.onListenSourceChanged,
                            onSetTranslation: actions.onSetCaptionTranslation, onOpenPage: onOpenPage)
        case .meeting: MeetingSettings(model: model, onOpenPage: onOpenPage)
        case .shortcuts: ShortcutSettings(model: model)
        case .ai: AISettings(model: model, onOpenPage: onOpenPage)
        case .models: ModelSettings(model: model, onOpenPage: onOpenPage)
        case .general: GeneralSettings(model: model)
        case .privacy: PrivacySettings(model: model, meetingStore: meetingStore, transcriptionStore: transcriptionStore)
        case .about: AboutSettings(model: model, onOpenOnboarding: actions.onOpenOnboarding)
        }
    }
}

// MARK: - 设置页的组件

/// 一页设置：标题、一句说明，下面是几组设置。
struct SettingsForm<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        PageBody {
            PageHeading(title: title, message: description)
            content()
        }
    }
}

/// 一组设置：组名、一张卡片（每一行之间一条细线）、卡片下面的说明。
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(Theme.heading).foregroundStyle(Theme.text)
            }
            SwiftUI.Group(subviews: content()) { rows in
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .cardStyle()
            if let footer {
                Text(footer)
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 卡片里的一行：左边是名字和一句说明，右边是开关、选择框或图标按钮。
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.help = help
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                if let help {
                    Text(help)
                        .font(Theme.small)
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 卡片最下面的一行浅灰提示：例如"用的是本机 Ollama"，右边一个跳到相关设置页的按钮。
struct SettingsNote: View {
    let symbol: String
    var tint: Color = Theme.secondaryText
    let text: String
    var onGo: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onGo {
                IconButton("arrow.up.right", help: "打开", size: 28, action: onGo)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
    }
}

/// 打开网页或做一件事的一行：图标、名字、说明，右边一个图标按钮。
/// 一项权限：图标、名字和说明，右边是状态（已允许绿、还没允许黄、没用到或不知道灰）和打开系统设置的按钮
/// （还没允许时是描边的，提醒去点）。
struct PermissionStatusRow: View {
    enum Status { case granted, missing, unknown, unused }

    let symbol: String
    let title: String
    let detail: String
    let status: Status
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                Text(detail).font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch status {
            case .granted: PropertyChip(symbol: "checkmark.circle", text: String(localized: "已允许"), tint: Theme.Tint.local)
            case .missing: PropertyChip(symbol: "exclamationmark.circle", text: String(localized: "还没允许"), tint: Theme.Tint.progress)
            case .unknown: PropertyChip(symbol: "questionmark.circle", text: String(localized: "用到时会询问"))
            case .unused: PropertyChip(symbol: "minus", text: String(localized: "没用到"))
            }
            IconButton("arrow.up.right", help: "打开系统设置", size: 28, outlined: status == .missing, action: action)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }
}

struct SettingsLinkRow: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.secondaryText
    var help: String?
    var buttonSymbol = "arrow.up.right"
    let action: () -> Void

    init(_ title: String, symbol: String, tint: Color = Theme.secondaryText, help: String? = nil,
         buttonSymbol: String = "arrow.up.right", action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.buttonSymbol = buttonSymbol
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint).frame(width: 18)
            Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
            if let help {
                Text(help).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(buttonSymbol, helpText: title, size: 28, action: action)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}

/// AI 服务用的是哪个：本机的说明不联网，云端的说明文字会发给它。`use` 是用在哪里（翻译、总结），写在句子开头。
enum AIUse { case general, translation, summary }

@MainActor
private func aiServiceNote(_ config: AppConfig, use: AIUse = .general) -> String {
    let ai = config.ai
    guard ai.isConfigured else { return String(localized: "还没设置 AI 服务") }
    if ai.service == .apple {
        return switch use {
        case .general: String(localized: "用的是 Apple 智能，文字不离开这台 Mac")
        case .translation: String(localized: "翻译用的是 Apple 智能，文字不离开这台 Mac")
        case .summary: String(localized: "总结用的是 Apple 智能，文字不离开这台 Mac")
        }
    }
    let host = AIProvider.detect(ai).map(ProviderPicker.title) ?? URL(string: ai.baseURL)?.host ?? ai.baseURL
    let name = ai.model.isEmpty ? host : "\(host) · \(ai.model)"
    if ai.isLocal {
        return switch use {
        case .general: String(localized: "用的是本机 \(name)，文字不离开这台 Mac")
        case .translation: String(localized: "翻译用的是本机 \(name)，文字不离开这台 Mac")
        case .summary: String(localized: "总结用的是本机 \(name)，文字不离开这台 Mac")
        }
    }
    return switch use {
    case .general: String(localized: "用的是 \(name)，文字会发给这个服务")
    case .translation: String(localized: "翻译用的是 \(name)，字幕会发给这个服务")
    case .summary: String(localized: "总结用的是 \(name)，会议文字会发给这个服务")
    }
}

/// 正在发声的应用，加上已经选中但现在没有声音的那个。
@MainActor
private func sourceChoices(_ apps: [AudioSourceApp], current: String) -> [AudioSourceApp] {
    guard !current.isEmpty, !apps.contains(where: { $0.bundleID == current }) else { return apps }
    return [AudioSourceApp(bundleID: current, name: AudioProcesses.name(of: current))] + apps
}

/// 收听来源：全部声音，或者某一个正在发声的应用。
private struct SourcePicker: View {
    let selection: Binding<String>
    let apps: [AudioSourceApp]

    var body: some View {
        SelectField(selection: selection, sections: [
            [("", String(localized: "全部声音"))],
            sourceChoices(apps, current: selection.wrappedValue).map { ($0.bundleID, $0.name) },
        ])
    }
}

// MARK: - 功能

/// 说话输入：麦克风、整理文字的方式、排版和词库。快捷键在「快捷键」里。
struct DictationSettings: View {
    let model: AppModel
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }
    @ViewState private var microphones: [AudioInputDevice] = []
    @ViewState private var defaultMicrophone: AudioInputDevice?

    private var config: AppConfig { model.configStore.config }

    /// 说话输入实际会用的麦克风是蓝牙耳机时返回它（选了"系统默认"、默认的是 AirPods 时也算）。
    private var bluetoothMicrophone: AudioInputDevice? {
        let used = microphones.first { $0.uid == config.microphone } ?? defaultMicrophone
        return used?.isBluetooth == true ? used : nil
    }

    var body: some View {
        SettingsForm(String(localized: "说话输入"),
                     description: String(localized: "在任何输入框里按住快捷键说话，松开后把整理好的文字粘贴到光标处。快捷键在“快捷键”里改。")) {
            SettingsGroup(String(localized: "录音")) {
                SettingsRow(String(localized: "麦克风"), help: String(localized: "没连上时用系统默认的麦克风")) {
                    SelectField(selection: model.configStore.binding(\.microphone), sections: [
                        [("", defaultMicrophone.map { String(localized: "系统默认（\($0.name)）") } ?? String(localized: "系统默认"))],
                        microphones.map { ($0.uid, $0.name) }
                            + (!config.microphone.isEmpty && !microphones.contains { $0.uid == config.microphone }
                               ? [(config.microphone, String(localized: "已选的麦克风（未连接）"))] : []),
                    ])
                }
                if let bluetooth = bluetoothMicrophone {
                    // 蓝牙耳机的麦克风打开时要先切到通话模式，开头一两秒没有声音（issue #1）
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("正在用蓝牙耳机的麦克风（\(bluetooth.name)）：每次开始录音都要先切换到通话模式，开头一两秒录不到，耳机音质也会暂时变差。建议改用 Mac 自带的麦克风，耳机照常用来听。")
                            .font(Theme.small)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let builtIn = microphones.first(where: \.isBuiltIn) {
                            IconButton("laptopcomputer", help: "改用 Mac 自带的麦克风", size: 26, tint: Theme.Tint.dictation,
                                       outlined: true) {
                                model.configStore.update { $0.microphone = builtIn.uid }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                SettingsRow(String(localized: "显示实时文字"), help: String(localized: "说话时在指示器里显示识别出的文字")) {
                    Toggle("显示实时文字", isOn: model.configStore.binding(\.livePreview)).labelsHidden()
                }
            }
            SettingsGroup(String(localized: "整理文字"), footer: cleanupFooter) {
                SettingsRow(String(localized: "整理文字"),
                            help: String(localized: "用 AI 去掉口头禅，修正口误和标点。关闭后直接输出识别结果")) {
                    Toggle("整理文字", isOn: Binding(get: { model.cleanupEnabled }, set: { model.cleanupEnabled = $0 }))
                        .labelsHidden()
                }
                SettingsRow(String(localized: "整理强度"), help: config.cleanupLevel.summary) {
                    SelectField(selection: model.configStore.binding(\.cleanupLevel),
                                options: CleanupLevel.allCases.map { ($0, $0.title) })
                }
                .disabled(!model.cleanupEnabled)
                SettingsRow(String(localized: "整理模式"), help: String(localized: "按场合调整语气：聊天更口语，邮件更书面")) {
                    SelectField(selection: model.configStore.binding(\.style),
                                options: CleanupStyle.allCases.map { ($0, $0.title) })
                }
                .disabled(!model.cleanupEnabled)
                SettingsRow(String(localized: "输出语言"), help: String(localized: "说中文也可以直接输出英文等其他语言")) {
                    SelectField(selection: model.configStore.binding(\.outputLanguage), sections: [
                        [(OutputLanguage.original, OutputLanguage.original.title)],
                        OutputLanguage.allCases.filter(\.isTranslation).map { ($0, $0.title) },
                    ])
                }
                .disabled(!model.cleanupEnabled)
                SettingsNote(symbol: "sparkles", tint: Theme.Tint.ai,
                             text: aiServiceNote(config)) { onOpenPage(.ai) }
            }
            SettingsGroup(String(localized: "排版和词库")) {
                SettingsRow(String(localized: "中英文排版"),
                            help: String(localized: "在中文和英文、数字之间加空格，统一用全角标点")) {
                    Toggle("中英文排版", isOn: model.configStore.binding(\.typography)).labelsHidden()
                }
                SettingsRow(String(localized: "提示加入词库"),
                            help: String(localized: "粘贴后发现你在输入框里改过的词，在词库里提示加入，确认后才加入")) {
                    Toggle("提示加入词库", isOn: model.configStore.binding(\.learnCorrections)).labelsHidden()
                }
            }
        }
        .task {
            // 插拔麦克风后自动刷新
            while !Task.isCancelled {
                let devices = AudioDevices.inputDevices()
                if devices != microphones { microphones = devices }
                let fallback = AudioDevices.defaultInput()
                if fallback != defaultMicrophone { defaultMicrophone = fallback }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var cleanupFooter: String? {
        guard model.cleanupEnabled else { return nil }
        if config.style != .standard { return config.style.summary }
        return nil
    }
}

/// 实时字幕：收听哪个应用、字幕条的样子、翻译。开始和停止在首页和菜单栏里。
struct CaptionSettings: View {
    let model: AppModel
    var onSourceChanged: () -> Void = {}
    var onSetTranslation: (Bool) -> Void = { _ in }
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }
    @ViewState private var apps: [AudioSourceApp] = []

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        SettingsForm(String(localized: "实时字幕"),
                     description: String(localized: "给电脑正在播放的声音加字幕：视频、网课、线上会议都可以。按 ⌃⌥C 开始或停止，快捷键在“快捷键”里改。")) {
            SettingsGroup(String(localized: "收听")) {
                SettingsRow(String(localized: "收听来源"), help: String(localized: "只听某一个应用时，其他应用的声音不会出字幕")) {
                    SourcePicker(selection: Binding(get: { config.listenSource }, set: { value in
                        model.configStore.update { $0.listenSource = value }
                        onSourceChanged()
                    }), apps: apps)
                }
            }
            SettingsGroup(String(localized: "字幕条")) {
                CaptionPreview(style: config.captionStyle, size: config.captionSize, translate: config.captionTranslate)
                SettingsRow(String(localized: "样式"), help: String(localized: "深色适合视频，浅色适合文档")) {
                    SelectField(selection: model.configStore.binding(\.captionStyle),
                                options: CaptionStyle.allCases.map { ($0, $0.title) })
                }
                SettingsRow(String(localized: "文字大小")) {
                    SelectField(selection: model.configStore.binding(\.captionSize),
                                options: CaptionSize.allCases.map { ($0, $0.title) })
                }
                SettingsRow(String(localized: "没有声音 10 秒后隐藏"), help: String(localized: "有声音时自动重新出现")) {
                    Toggle("没有声音 10 秒后隐藏", isOn: model.configStore.binding(\.captionAutoHide)).labelsHidden()
                }
            }
            SettingsGroup(String(localized: "翻译")) {
                SettingsRow(String(localized: "翻译字幕"), help: String(localized: "用 AI 服务翻译每一句，译文显示在原文下面")) {
                    Toggle("翻译字幕", isOn: Binding(get: { config.captionTranslate }, set: { onSetTranslation($0) }))
                        .labelsHidden()
                }
                SettingsRow(String(localized: "翻译成")) {
                    SelectField(selection: model.configStore.binding(\.captionLanguage),
                                options: OutputLanguage.allCases.filter(\.isTranslation).map { ($0, $0.title) })
                }
                .disabled(!config.captionTranslate)
                SettingsRow(String(localized: "边听边翻译"),
                            help: String(localized: "一句没说完就先翻，译文会随时更新")) {
                    Toggle("边听边翻译", isOn: model.configStore.binding(\.captionLiveTranslate)).labelsHidden()
                }
                .disabled(!config.captionTranslate)
                SettingsNote(symbol: "sparkles", tint: Theme.Tint.ai,
                             text: aiServiceNote(config, use: .translation)) { onOpenPage(.ai) }
            }
        }
        .task {
            // 正在播放声音的应用随时会变，定期刷新
            while !Task.isCancelled {
                let playing = AudioProcesses.playingApps()
                if playing != apps { apps = playing }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// 会议记录：收听哪个应用、要不要留录音、区分说话人、自动总结。占用的空间在「隐私与数据」里。
struct MeetingSettings: View {
    let model: AppModel
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }
    @ViewState private var apps: [AudioSourceApp] = []

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        SettingsForm(String(localized: "会议记录"),
                     description: String(localized: "同时录下你的麦克风和电脑里会议的声音，会后在这台 Mac 上整理成文字、分出说话人。按 ⌃⌥M 开始或结束。")) {
            SettingsGroup(String(localized: "录音")) {
                SettingsRow(String(localized: "收听来源"), help: String(localized: "线上会议建议只听会议应用，例如腾讯会议、Zoom")) {
                    SourcePicker(selection: model.configStore.binding(\.meetingSource), apps: apps)
                }
                SettingsRow(String(localized: "会后保留录音"),
                            help: String(localized: "录音存在这台 Mac 上，可以回放；关掉后只留文字")) {
                    Toggle("会后保留录音", isOn: model.configStore.binding(\.meetingKeepRecording)).labelsHidden()
                }
            }
            SettingsGroup(String(localized: "整理")) {
                SettingsRow(String(localized: "区分说话人"),
                            help: String(localized: "会后把对方分成说话人 1、2、3，可以改名。需要说话人模型（\(Self.diarizationSize(model))）")) {
                    if model.diarizationModels.isReady {
                        Toggle("区分说话人", isOn: model.configStore.binding(\.meetingDiarize)).labelsHidden()
                    } else {
                        IconButton("arrow.down.to.line", help: "去下载说话人模型", tint: Theme.Tint.speech, outlined: true) {
                            onOpenPage(.models)
                        }
                    }
                }
                SettingsRow(String(localized: "会议结束后自动生成总结"),
                            help: String(localized: "默认关闭。打开后，每场会议结束都会把文字发给 AI 服务")) {
                    Toggle("会议结束后自动生成总结", isOn: model.configStore.binding(\.meetingAutoSummary)).labelsHidden()
                }
                .disabled(!config.ai.isConfigured)
                SettingsNote(symbol: "sparkles", tint: Theme.Tint.ai,
                             text: aiServiceNote(config, use: .summary)) { onOpenPage(.ai) }
            }
            StorageNote(text: String(localized: "会议记录占用的空间，在“隐私与数据”里查看和清理")) { onOpenPage(.privacy) }
        }
        .task {
            while !Task.isCancelled {
                let playing = AudioProcesses.playingApps()
                if playing != apps { apps = playing }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension MeetingSettings {
    /// 说话人模型的大小（29 MB）
    static func diarizationSize(_ model: AppModel) -> String {
        ByteCountFormatter.string(fromByteCount: model.diarizationModels.totalSize ?? 29_000_000, countStyle: .file)
    }
}

/// 字幕条的预览：深色的背景上一条字幕，选了翻译时下面加一行译文。
private struct CaptionPreview: View {
    let style: CaptionStyle
    let size: CaptionSize
    let translate: Bool

    var body: some View {
        let dark = style == .dark
        VStack(spacing: 4) {
            Text(verbatim: "Let's start with the release date this week.")
                .font(.system(size: size.pointSize * 0.62, weight: .medium))
                .foregroundStyle(dark ? .white : Theme.text)
            if translate {
                Text(verbatim: "我们先定一下这周的发布时间。")
                    .font(.system(size: size.pointSize * 0.5))
                    .foregroundStyle(dark ? .white.opacity(0.75) : Theme.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(dark ? AnyShapeStyle(.black.opacity(0.82)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.23), Color(red: 0.2, green: 0.25, blue: 0.33)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// 页面最下面一行灰字：硬盘图标和一句说明（占用的空间在哪里看）。
struct StorageNote: View {
    let text: String
    var onGo: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").font(.system(size: 11, weight: .medium))
            Text(text)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.secondaryText)
        .contentShape(Rectangle())
        .onTapGesture { onGo?() }
    }
}

// MARK: - 共用

/// 快捷键：所有快捷键都在这一页。说话输入的几个可以改，字幕和会议的是固定的。
struct ShortcutSettings: View {
    let model: AppModel

    private var config: AppConfig { model.configStore.config }

    private var fnFooter: String? {
        guard config.hotkey == .fn || config.activeRewriteHotkey == .fn else { return nil }
        return String(localized: "使用 Fn 时，请在“系统设置 › 键盘”里把“按下 🌐 键时”设为“无操作”。")
    }

    var body: some View {
        SettingsForm(String(localized: "快捷键"),
                     description: String(localized: "所有快捷键都在这一页。前三组在任何应用里都能用。")) {
            SettingsGroup(String(localized: "说话输入"), footer: fnFooter) {
                SettingsRow(String(localized: "按住说话"), help: String(localized: "按住开始录音，松开输出文字，按 Esc 取消")) {
                    SelectField(selection: model.configStore.binding(\.hotkey),
                                options: HotkeyKey.allCases.map { ($0, "\($0.symbol) \($0.title)") })
                }
                SettingsRow(String(localized: "双击免按住录音"), help: String(localized: "双击上面的键开始，再按一次结束")) {
                    Toggle("双击免按住录音", isOn: model.configStore.binding(\.handsFree)).labelsHidden()
                }
                SettingsRow(String(localized: "改写选中文字"), help: String(localized: "选中一段文字，按住这个键说出要怎么改")) {
                    SelectField(selection: Binding(
                        get: { config.activeRewriteHotkey },
                        set: { value in model.configStore.update { $0.rewriteHotkey = value } }
                    ), sections: [
                        [(HotkeyKey?.none, String(localized: "关闭"))],
                        // 不能和按住说话的键相同
                        HotkeyKey.allCases.filter { $0 != config.hotkey }.map { (HotkeyKey?.some($0), "\($0.symbol) \($0.title)") },
                    ])
                }
            }
            SettingsGroup(String(localized: "实时字幕")) {
                SettingsRow(String(localized: "开始或停止收听")) { KeyHint("⌃⌥C") }
                SettingsRow(String(localized: "粘贴刚才那段"), help: String(localized: "把字幕里刚才那段话整理后粘贴到光标处，收听时才有效")) {
                    KeyHint("⌃⌥V")
                }
            }
            SettingsGroup(String(localized: "会议记录")) {
                SettingsRow(String(localized: "开始或结束会议记录")) { KeyHint("⌃⌥M") }
            }
            SettingsGroup(String(localized: "主窗口里")) {
                SettingsRow(String(localized: "切换首页、转写、资料库、词库")) { KeyHint("⌘1–4") }
                SettingsRow(String(localized: "在资料库里搜索")) { KeyHint("⌘F") }
                SettingsRow(String(localized: "打开设置 · 返回")) {
                    HStack(spacing: 4) { KeyHint("⌘,"); KeyHint("⌘[") }
                }
            }
        }
    }
}

/// AI 服务：选服务、填接口，下面列出用到它的几个功能。
struct AISettings: View {
    let model: AppModel
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        SettingsForm(String(localized: "AI 服务"),
                     description: String(localized: "整理文字、语音改写、字幕翻译和会议总结都用这里的服务。选本机模型或 Apple 智能时，文字不离开这台 Mac。")) {
            AIConfigEditor(model: model)
            SettingsGroup(String(localized: "用在这些地方")) {
                usage(String(localized: "整理文字"), symbol: "wand.and.stars", tint: Theme.Tint.dictation,
                      on: config.cleanupEnabled, page: .dictation)
                usage(String(localized: "语音改写"), symbol: "wand.and.sparkles", tint: Theme.Tint.ai,
                      on: config.activeRewriteHotkey != nil, page: .shortcuts)
                usage(String(localized: "字幕翻译"), symbol: "character.bubble", tint: Theme.Tint.captions,
                      on: config.captionTranslate, page: .captions)
                usage(String(localized: "会议总结"), symbol: "list.bullet.rectangle", tint: Theme.Tint.meeting,
                      state: config.meetingAutoSummary ? String(localized: "自动生成") : String(localized: "点了才生成"),
                      page: .meeting)
            }
        }
    }

    private func usage(_ title: String, symbol: String, tint: Color, on: Bool? = nil, state: String? = nil,
                       page: MainNavigation.SettingsPage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint).frame(width: 18)
            Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
            Text("设置 › \(page.title)").font(Theme.small).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            let ready = config.ai.isConfigured
            Text(!ready ? String(localized: "要先设置") : state ?? (on == true ? String(localized: "开") : String(localized: "关")))
                .font(Theme.smallMedium)
                .foregroundStyle(!ready || on == false ? Theme.secondaryText : Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
            IconButton("arrow.up.right", helpText: String(localized: "打开“\(page.title)”"), size: 28) { onOpenPage(page) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}

/// 识别模型：语音识别模型（默认 SenseVoice）和区分说话人用的模型。
struct ModelSettings: View {
    let model: AppModel
    var onOpenPage: (MainNavigation.SettingsPage) -> Void = { _ in }
    @ViewState private var size: Int64 = 0

    var body: some View {
        SettingsForm(String(localized: "识别模型"),
                     description: String(localized: "所有模型都在这台 Mac 上运行，声音不上传。说话输入、实时字幕、会议记录和转写都用这里选的模型。")) {
            SettingsGroup(String(localized: "语音识别模型")) {
                SpeechModelList(model: model)
            }
            SettingsGroup(String(localized: "说话人模型")) {
                DiarizationModelRow(manager: model.diarizationModels)
            }
            StorageNote(text: String(localized: "模型共占用 \(PrivacySettings.size(size))，在“隐私与数据”里可以看到所有内容占用的空间")) {
                onOpenPage(.privacy)
            }
        }
        .task {
            while !Task.isCancelled {
                let next = PrivacySettings.directorySize(PrivacySettings.Usage.models.folder)
                if next != size { size = next }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - 系统

/// 通用：外观和语言，开机启动、提示音、自动检查更新。版本和手动检查在「关于」里。
struct GeneralSettings: View {
    let model: AppModel
    @ViewState private var loginStatus = LoginItem.status
    @ViewState private var loginError: String?
    @ViewState private var language = AppLanguage.selected

    var body: some View {
        SettingsForm(String(localized: "通用"),
                     description: String(localized: "Tidytalk 的外观和语言、怎么启动、怎么提醒你、怎么更新。")) {
            SettingsGroup(String(localized: "外观和语言")) {
                SettingsRow(String(localized: "外观"), help: String(localized: "跟随系统的浅色和深色，或者固定用一种")) {
                    LinearTabs(selection: Binding(get: { model.configStore.config.appearance }, set: { value in
                        model.configStore.update { $0.appearance = value }
                        value.apply()
                    }), items: AppAppearance.allCases.map {
                        .init(value: $0, title: $0.title, symbol: Self.symbol($0))
                    }, compact: true)
                }
                SettingsRow(String(localized: "语言"),
                            help: String(localized: "界面文字的语言。跟随系统时，按 macOS 的首选语言显示")) {
                    SelectField(selection: Binding(get: { language }, set: { value in
                        AppLanguage.select(value)
                        language = value
                    }), options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                if language.code != AppLanguage.runningCode {
                    // 语言要重新打开才生效
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                        Text("重新打开 Tidytalk 后换成 \(AppLanguage.name(language.code))")
                            .font(Theme.small).foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 8)
                        IconButton("arrow.clockwise", help: "现在重新打开 Tidytalk", size: 28, prominent: true,
                                   action: AppLanguage.relaunch)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.vertical, 8)
                    .background(Theme.canvas)
                }
            }
            SettingsGroup(String(localized: "启动和更新")) {
                SettingsRow(String(localized: "开机自动启动"), help: loginHelp) {
                    HStack(spacing: 6) {
                        if loginStatus == .requiresApproval {
                            IconButton("arrow.up.forward.app", help: "打开登录项设置", size: 26, tint: Theme.warning) {
                                LoginItem.openSettings()
                            }
                        }
                        Toggle("开机自动启动", isOn: Binding(
                            get: { loginStatus != .disabled },
                            set: { value in
                                loginError = LoginItem.setEnabled(value)
                                loginStatus = LoginItem.status
                            }
                        ))
                        .labelsHidden()
                    }
                }
                SettingsRow(String(localized: "播放提示音"), help: String(localized: "开始和结束录音时各响一声")) {
                    Toggle("播放提示音", isOn: model.configStore.binding(\.sounds)).labelsHidden()
                }
                if UpdateChecker.isConfigured {
                    SettingsRow(String(localized: "自动检查更新"),
                                help: String(localized: "启动时检查，每天最多一次。版本和手动检查在“关于”里")) {
                        Toggle("自动检查更新", isOn: model.configStore.binding(\.autoUpdateCheck)).labelsHidden()
                    }
                }
            }
        }
        .task {
            // 用户在系统设置里允许登录项后自动刷新
            while !Task.isCancelled {
                let status = LoginItem.status
                if status != loginStatus { loginStatus = status }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func symbol(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: "display"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var loginHelp: String {
        if let loginError { return loginError }
        if loginStatus == .requiresApproval { return String(localized: "需要在系统设置里允许") }
        return String(localized: "登录 Mac 后在菜单栏里待命")
    }
}

/// 隐私与数据：权限、说话记录保存多久、各类内容占用的空间，以及完整的隐私说明。
struct PrivacySettings: View {
    let model: AppModel
    let meetingStore: MeetingStore
    var transcriptionStore: TranscriptionStore?
    @ViewState private var sizes: [Usage: Int64] = [:]
    @ViewState private var confirmClear = false

    private var config: AppConfig { model.configStore.config }

    enum Usage: CaseIterable {
        case models, meetings, transcriptions, dictations, tools

        var title: String {
            switch self {
            case .models: String(localized: "识别模型")
            case .meetings: String(localized: "会议记录")
            case .transcriptions: String(localized: "转写")
            case .dictations: String(localized: "说话记录")
            case .tools: String(localized: "yt-dlp")
            }
        }

        var color: Color {
            switch self {
            case .models: Theme.Tint.speech
            case .meetings: Theme.Tint.meeting
            case .transcriptions: Theme.Tint.vocabulary
            case .dictations: Theme.Tint.dictation
            case .tools: Theme.Tint.neutral
            }
        }

        var folder: URL {
            let root = URL.applicationSupportDirectory.appending(path: "Tidytalk", directoryHint: .isDirectory)
            return switch self {
            case .models: root.appending(path: "Models", directoryHint: .isDirectory)
            case .meetings: MeetingStore.defaultRoot
            case .transcriptions: TranscriptionStore.defaultRoot
            case .dictations: DictationStore.defaultRoot
            case .tools: root.appending(path: "Tools", directoryHint: .isDirectory)
            }
        }
    }

    var body: some View {
        SettingsForm(String(localized: "隐私与数据"),
                     description: String(localized: "声音始终在这台 Mac 上识别。这里管理系统权限、说话记录，以及 Tidytalk 在这台 Mac 上占用的空间。")) {
            SettingsGroup(String(localized: "权限")) {
                PermissionStatusRow(symbol: "mic", title: String(localized: "麦克风"), detail: String(localized: "说话输入、会议记录"),
                                    status: model.microphoneGranted ? .granted : .missing) {
                    if Permissions.microphone == .notDetermined {
                        Task {
                            _ = await Permissions.requestMicrophone()
                            model.refreshPermissions()
                        }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
                PermissionStatusRow(symbol: "accessibility", title: String(localized: "辅助功能"),
                                    detail: String(localized: "监听快捷键、把文字粘贴到光标处、读取选中的文字"),
                                    status: model.accessibilityGranted ? .granted : .missing) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                if !model.accessibilityGranted {
                    AccessibilityHelp(model: model).padding(.horizontal, 16).padding(.vertical, 8)
                }
                PermissionStatusRow(symbol: "rectangle.on.rectangle", title: String(localized: "录制系统音频"),
                                    detail: String(localized: "实时字幕、会议记录"),
                                    status: model.systemAudio == .granted ? .granted : model.systemAudio == .denied ? .missing : .unknown,
                                    action: Permissions.openSystemAudioSettings)
                PermissionStatusRow(symbol: "waveform", title: String(localized: "语音识别"),
                                    detail: String(localized: "只在选了 Apple 系统识别时需要"),
                                    status: config.speechModel == .apple ? .granted : .unused) {
                    Permissions.openSpeechRecognitionSettings()
                }
            }
            SettingsGroup(String(localized: "说话记录")) {
                SettingsRow(String(localized: "保存说话记录"),
                            help: String(localized: "整理后的文字和识别原文存在这台 Mac 上，资料库里可以搜索。关掉后只在这次打开期间放在内存里，退出就清空")) {
                    Toggle("保存说话记录", isOn: Binding(get: { config.history },
                                                    set: { model.setHistory(saving: $0) })).labelsHidden()
                }
                SettingsRow(String(localized: "保留多久"), help: String(localized: "超过时间的说话记录自动删除，会议和转写不受影响")) {
                    SelectField(selection: Binding(get: { config.historyDays }, set: { model.setHistory(days: $0) }),
                                options: AppConfig.historyDayChoices.map { ($0, Self.retentionTitle($0)) })
                }
                .disabled(!config.history)
                SettingsRow(String(localized: "清空说话记录"), help: clearHelp) {
                    IconButton("trash", help: "清空说话记录", size: 28, tint: Theme.danger, outlined: true) {
                        confirmClear = true
                    }
                    .disabled(model.history.isEmpty)
                }
            }
            SettingsGroup(String(localized: "占用空间")) {
                storage
                ForEach(Usage.allCases, id: \.self) { usage in
                    HStack(spacing: 10) {
                        Circle().fill(usage.color).frame(width: 8, height: 8)
                        Text(usage.title).font(Theme.body).foregroundStyle(Theme.text)
                        Spacer()
                        Text(Self.size(sizes[usage] ?? 0)).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        IconButton("folder", help: "在访达中显示", size: 26, tint: Theme.Tint.meeting) {
                            try? FileManager.default.createDirectory(at: usage.folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([usage.folder])
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                }
            }
            SettingsGroup {
                SettingsLinkRow(String(localized: "隐私说明"), symbol: "checkmark.shield", tint: Theme.Tint.local,
                                help: String(localized: "存了什么、什么时候联网、哪些文字会发给 AI 服务"),
                                buttonSymbol: "arrow.up.right.square") {
                    HelpLinks.open(HelpLinks.privacy)
                }
            }
        }
        .confirmationDialog("清空所有说话记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { model.clearHistory() }
        } message: {
            Text("资料库里的说话记录都会删除，不能恢复。会议和转写不受影响。")
        }
        .task {
            // 授权、占用空间随时会变，定期刷新
            while !Task.isCancelled {
                model.refreshPermissions()
                var next: [Usage: Int64] = [:]
                for usage in Usage.allCases { next[usage] = Self.directorySize(usage.folder) }
                if next != sizes { sizes = next }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var clearHelp: String {
        let count = model.history.count
        guard count > 0 else { return String(localized: "现在没有说话记录") }
        guard config.history else { return String(localized: "现在内存里有 \(count.formatted()) 条，退出 Tidytalk 后清空") }
        let size = sizes[.dictations].map { String(localized: "，约 \(Self.size($0))") } ?? ""
        return String(localized: "现在有 \(count.formatted()) 条") + size
    }

    /// 一条横条，按各类内容占用的比例分段。
    private var storage: some View {
        let total = sizes.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(Self.size(total)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text("都在这台 Mac 上").font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Usage.allCases, id: \.self) { usage in
                        let part = total > 0 ? CGFloat(sizes[usage] ?? 0) / CGFloat(total) : 0
                        if part > 0 {
                            Rectangle().fill(usage.color).frame(width: max(3, proxy.size.width * part))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Theme.subtle)
            .clipShape(Capsule())
        }
        .padding(16)
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "一直保留")
        case 365: String(localized: "一年")
        default: String(localized: "\(String(days)) 天")
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// 关于：版本、检查更新、帮助和资料，以及重新打开设置引导、配置文件。
struct AboutSettings: View {
    let model: AppModel
    var onOpenOnboarding: () -> Void = {}

    var body: some View {
        PageBody {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Tidytalk").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("版本 \(UpdateChecker.currentVersion) · 按住说话，松开就是整理好的文字")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                if UpdateChecker.isConfigured {
                    if let latest = UpdateChecker.latestKnownVersion {
                        if AppVersion.isNewer(latest, than: UpdateChecker.currentVersion) {
                            PropertyChip(symbol: "arrow.down.circle", text: String(localized: "有新版本 \(latest)"), tint: Theme.Tint.meeting)
                        } else {
                            PropertyChip(symbol: "checkmark.circle", text: String(localized: "已是最新版本"), tint: Theme.Tint.local)
                        }
                    }
                    IconButton("arrow.clockwise", help: "检查更新", outlined: true) {
                        Task { await UpdateChecker.check(userInitiated: true) }
                    }
                }
            }
            .padding(20)
            .cardStyle()
            SettingsGroup(String(localized: "帮助和资料")) {
                SettingsLinkRow(String(localized: "使用指南"), symbol: "book", tint: Theme.Tint.meeting,
                                help: String(localized: "每个功能怎么用、常见问题")) { HelpLinks.open(HelpLinks.guide) }
                SettingsLinkRow(String(localized: "隐私说明"), symbol: "checkmark.shield", tint: Theme.Tint.local,
                                help: String(localized: "存了什么、什么时候联网")) { HelpLinks.open(HelpLinks.privacy) }
                SettingsLinkRow(String(localized: "更新日志"), symbol: "list.bullet.rectangle", tint: Theme.Tint.vocabulary,
                                help: String(localized: "每个版本改了什么")) { HelpLinks.open(HelpLinks.changelog) }
                SettingsLinkRow(String(localized: "源代码"), symbol: "chevron.left.forwardslash.chevron.right",
                                tint: Theme.text, help: String(localized: "MIT 许可证，在 GitHub 上")) {
                    HelpLinks.open(HelpLinks.source)
                }
                SettingsLinkRow(String(localized: "反馈问题"), symbol: "bubble.left", tint: Theme.Tint.ai,
                                help: String(localized: "在 GitHub 上提 issue")) { HelpLinks.open(HelpLinks.issues) }
            }
            SettingsGroup(String(localized: "其他")) {
                SettingsRow(String(localized: "重新打开设置引导"), help: String(localized: "一步步检查权限、AI 服务和识别模型")) {
                    IconButton("slider.horizontal.3", help: "打开设置引导", outlined: true, action: onOpenOnboarding)
                }
                SettingsRow(String(localized: "打开配置文件"), help: String(localized: "~/.tidytalk.json，用文本编辑器修改高级选项")) {
                    IconButton("doc.badge.gearshape", help: "在编辑器中打开", outlined: true) {
                        model.configStore.openInEditor()
                    }
                }
            }
            Text("用到的开源项目：SenseVoice、Qwen3-ASR、Whisper、sherpa-onnx、yt-dlp 等。")
                .font(Theme.small)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
