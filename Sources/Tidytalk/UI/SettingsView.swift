import AppKit
import SwiftUI
import TidytalkCore

/// 设置窗口：使用 macOS 标准的偏好设置样式，标签页以图标形式放在标题栏的工具栏里。
enum SettingsWindow {
    static let width: CGFloat = 560

    @MainActor
    static func make(model: AppModel, onOpenOnboarding: @escaping () -> Void = {},
                     onToggleListening: @escaping () -> Void = {},
                     onListenSourceChanged: @escaping () -> Void = {},
                     onSetCaptionTranslation: @escaping (Bool) -> Void = { _ in }) -> NSWindow {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        // 每页高度按内容设定，切换时窗口跟着伸缩，和系统设置的偏好窗口一样
        tabs.addTabViewItem(item(String(localized: "通用"), symbol: "gearshape", height: 690,
                                 GeneralSettings(model: model, onOpenOnboarding: onOpenOnboarding)))
        tabs.addTabViewItem(item(String(localized: "说话输入"), symbol: "mic", height: 530, RecordingSettings(model: model)))
        tabs.addTabViewItem(item(String(localized: "识别模型"), symbol: "waveform", height: 410, ModelSettings(model: model)))
        tabs.addTabViewItem(item(String(localized: "配置 AI"), symbol: "sparkles", height: 640, AISettings(model: model)))
        tabs.addTabViewItem(item(String(localized: "词库"), symbol: "character.book.closed", height: 640, VocabularySettings(model: model)))
        tabs.addTabViewItem(item(String(localized: "实时字幕"), symbol: "captions.bubble", height: 610,
                                 ListenSettings(model: model, onToggle: onToggleListening, onSourceChanged: onListenSourceChanged,
                                                onSetTranslation: onSetCaptionTranslation)))

        let window = FocusFriendlyWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        if let first = tabs.tabViewItems.first?.viewController { window.setContentSize(first.preferredContentSize) }
        return window
    }

    @MainActor
    private static func item(_ title: String, symbol: String, height: CGFloat, _ view: some View) -> NSTabViewItem {
        let size = NSSize(width: width, height: height)
        let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.preferredContentSize = size
        // 工具栏样式的标签页会把当前页的标题显示为窗口标题
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// 通用：启动与更新、权限、历史记录，以及设置引导和配置文件。
struct GeneralSettings: View {
    let model: AppModel
    var onOpenOnboarding: () -> Void = {}
    @ViewState private var loginStatus = LoginItem.status
    @ViewState private var loginError: String?

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(
                    get: { loginStatus != .disabled },
                    set: { value in
                        loginError = LoginItem.setEnabled(value)
                        loginStatus = LoginItem.status
                    }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("需要在系统设置里允许").foregroundStyle(.orange)
                        Spacer()
                        Button("打开登录项设置") { LoginItem.openSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                if UpdateChecker.isConfigured {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { config.autoUpdateCheck },
                        set: { value in model.configStore.update { $0.autoUpdateCheck = value } }
                    ))
                    HStack {
                        Text("当前版本 \(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
                        Spacer()
                        Button("检查更新") { Task { await UpdateChecker.check(userInitiated: true) } }
                    }
                } else {
                    LabeledContent("版本", value: UpdateChecker.currentVersion)
                }
            } header: {
                Text("启动与更新")
            }

            permissions

            Section {
                Toggle("记住最近的结果", isOn: Binding(
                    get: { config.history },
                    set: { value in
                        model.configStore.update { $0.history = value }
                        if !value { model.clearHistory() }
                    }
                ))
                if config.history, !model.history.isEmpty {
                    HStack {
                        Text("已记住 \(model.history.count) 条").foregroundStyle(.secondary)
                        Spacer()
                        Button("清空") { model.clearHistory() }
                            .disabled(model.history.isEmpty)
                    }
                }
            } header: {
                Text("历史记录")
            } footer: {
                Text("可以在菜单栏的\"最近记录\"里再次粘贴。退出后清空。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("其他") {
                LabeledContent("设置引导") {
                    Button("打开", action: onOpenOnboarding)
                }
                LabeledContent("配置文件") {
                    Button("在编辑器中打开") { model.configStore.openInEditor() }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // 用户在系统设置里允许登录项、授权后自动刷新
            while !Task.isCancelled {
                let status = LoginItem.status
                if status != loginStatus { loginStatus = status }
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 权限：麦克风、辅助功能、录制系统音频，以及唯一一处隐私说明。
    private var permissions: some View {
        Section {
            PermissionRow(title: String(localized: "麦克风"), detail: String(localized: "用于录音"),
                          granted: model.microphoneGranted, actionTitle: String(localized: "授权")) {
                if Permissions.microphone == .notDetermined {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        model.refreshPermissions()
                    }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            }
            PermissionRow(title: String(localized: "辅助功能"),
                          detail: Typography.format(String(localized: "用于监听\(config.hotkey.shortName)键和粘贴文字")),
                          granted: model.accessibilityGranted, actionTitle: String(localized: "授权")) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if !model.accessibilityGranted {
                AccessibilityHelp(model: model)
            }
            // macOS 不提供查询这项授权的接口，只给出入口
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("录制系统音频")
                    Text("用于实时字幕，第一次收听时 macOS 会询问").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开系统设置") { Permissions.openSystemAudioSettings() }
            }
        } header: {
            Text("权限")
        } footer: {
            Text("声音只在这台 Mac 上识别，不会上传。开启整理文字或字幕翻译后，文字会发送给你配置的 AI 服务；选本机模型或 Apple 智能则不联网。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 说话输入：快捷键、麦克风，以及输出文字的排版。
struct RecordingSettings: View {
    let model: AppModel
    @ViewState private var microphones: [AudioInputDevice] = []

    private var config: AppConfig { model.configStore.config }

    private var hotkeyFooter: String {
        var text = String(localized: "按住说话，松开结束，按 Esc 取消。")
        if config.handsFree {
            text += String(localized: "双击可免按住录音，再按一次结束。")
        }
        if let rewrite = config.activeRewriteHotkey {
            text += String(localized: "选中文字后按住\(rewrite.shortName)说出修改要求，即可改写。")
        }
        if config.hotkey == .fn || config.activeRewriteHotkey == .fn {
            text += String(localized: "使用 Fn 时，请在\"系统设置 › 键盘\"里把\"按下 🌐 键时\"设为\"无操作\"。")
        }
        // 键名前后的空格由排版规则补上（中文与英文之间加空格，中文之间不加）
        return Typography.format(text)
    }

    var body: some View {
        Form {
            Section {
                Picker("按住说话", selection: Binding(
                    get: { config.hotkey },
                    set: { value in model.configStore.update { $0.hotkey = value } }
                )) {
                    ForEach(HotkeyKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("双击免按住录音", isOn: Binding(
                    get: { config.handsFree },
                    set: { value in model.configStore.update { $0.handsFree = value } }
                ))
                Picker("改写选中文字", selection: Binding(
                    get: { config.activeRewriteHotkey },
                    set: { value in model.configStore.update { $0.rewriteHotkey = value } }
                )) {
                    Text("关闭").tag(HotkeyKey?.none)
                    Divider()
                    // 不能和按住说话的键相同
                    ForEach(HotkeyKey.allCases.filter { $0 != config.hotkey }, id: \.self) {
                        // 键名前后的空格由排版规则补上
                        Text(Typography.format(String(localized: "按住\($0.title)")))
                            .tag(HotkeyKey?.some($0))
                    }
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text(hotkeyFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("麦克风", selection: Binding(
                    get: { config.microphone },
                    set: { value in model.configStore.update { $0.microphone = value } }
                )) {
                    Text("系统默认").tag("")
                    Divider()
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !config.microphone.isEmpty, !microphones.contains(where: { $0.uid == config.microphone }) {
                        Text("已选的麦克风（未连接）").tag(config.microphone)
                    }
                }
                Toggle("显示实时文字", isOn: Binding(
                    get: { config.livePreview },
                    set: { value in model.configStore.update { $0.livePreview = value } }
                ))
                Toggle("播放提示音", isOn: Binding(
                    get: { config.sounds },
                    set: { value in model.configStore.update { $0.sounds = value } }
                ))
            } header: {
                Text("录音")
            } footer: {
                Text("未连接时使用系统默认麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 排版在本地完成，和 AI 整理无关，关闭整理时也生效
            Section {
                Toggle("中英文排版规范", isOn: Binding(
                    get: { config.typography },
                    set: { value in model.configStore.update { $0.typography = value } }
                ))
            } header: {
                Text("排版")
            } footer: {
                Text("在中文与英文、数字之间加空格，统一使用全角标点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .task {
            // 插拔麦克风后自动刷新
            while !Task.isCancelled {
                let devices = AudioDevices.inputDevices()
                if devices != microphones { microphones = devices }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// 配置 AI：接口，以及整理强度、模式、输出语言。
struct AISettings: View {
    let model: AppModel

    private var config: AppConfig { model.configStore.config }

    private var modeFooter: String {
        // 标准模式的说明与强度重复，只在选了其他模式时补充
        var text = config.cleanupLevel.summary
        if config.style != .standard {
            // 英文句子之间要空格，中文不要
            let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
            text += (chinese ? "" : " ") + config.style.summary
        }
        if config.outputLanguage.isTranslation {
            text += String(localized: "整理后翻译成 \(config.outputLanguage.title)。")
        }
        return text
    }

    var body: some View {
        Form {
            Section {
                Toggle("整理文字", isOn: Binding(
                    get: { model.cleanupEnabled },
                    set: { model.cleanupEnabled = $0 }
                ))
            } footer: {
                Text("用 AI 去掉口头禅，修正口误和标点。关闭后直接输出识别结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI 服务") {
                AIConfigEditor(model: model)
            }
            .disabled(!model.cleanupEnabled && !config.captionTranslate)

            Section {
                Picker("整理强度", selection: Binding(
                    get: { config.cleanupLevel },
                    set: { value in model.configStore.update { $0.cleanupLevel = value } }
                )) {
                    ForEach(CleanupLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("整理模式", selection: Binding(
                    get: { config.style },
                    set: { value in model.configStore.update { $0.style = value } }
                )) {
                    ForEach(CleanupStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("输出语言", selection: Binding(
                    get: { config.outputLanguage },
                    set: { value in model.configStore.update { $0.outputLanguage = value } }
                )) {
                    Text(OutputLanguage.original.title).tag(OutputLanguage.original)
                    Divider()
                    ForEach(OutputLanguage.allCases.filter(\.isTranslation), id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
            } header: {
                Text("整理方式")
            } footer: {
                Text(modeFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.cleanupEnabled)

        }
        .formStyle(.grouped)
    }
}


/// 实时字幕：收听电脑播放的声音（视频、会议），在屏幕上显示字幕。
struct ListenSettings: View {
    let model: AppModel
    var onToggle: () -> Void = {}
    var onSourceChanged: () -> Void = {}
    var onSetTranslation: (Bool) -> Void = { _ in }
    @ViewState private var apps: [AudioSourceApp] = []

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(model.isListening ? String(localized: "停止收听") : String(localized: "开始收听")) { onToggle() }
                } label: {
                    Text(model.isListening ? String(localized: "正在收听") : String(localized: "收听电脑声音"))
                    Text(verbatim: "⌃⌥C")
                }
                Picker("收听来源", selection: Binding(
                    get: { config.listenSource },
                    set: { value in
                        model.configStore.update { $0.listenSource = value }
                        onSourceChanged()
                    }
                )) {
                    Text("全部声音").tag("")
                    if !sourceChoices.isEmpty { Divider() }
                    ForEach(sourceChoices, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                LabeledContent("粘贴刚才那段", value: "⌃⌥V")
            } header: {
                Text("收听")
            } footer: {
                Text("只收听某个应用时，其他声音不会出现在字幕里。收听时按 ⌃⌥V，或点字幕条上某一句旁边的\"粘贴\"，可以把听到的话整理后粘贴到光标处。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字幕") {
                Picker("样式", selection: Binding(
                    get: { config.captionStyle },
                    set: { value in model.configStore.update { $0.captionStyle = value } }
                )) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("文字大小", selection: Binding(
                    get: { config.captionSize },
                    set: { value in model.configStore.update { $0.captionSize = value } }
                )) {
                    ForEach(CaptionSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("没有声音 10 秒后隐藏", isOn: Binding(
                    get: { config.captionAutoHide },
                    set: { value in model.configStore.update { $0.captionAutoHide = value } }
                ))
            }

            Section {
                Toggle("翻译字幕", isOn: Binding(
                    get: { config.captionTranslate },
                    set: { value in onSetTranslation(value) }
                ))
                Picker("翻译成", selection: Binding(
                    get: { config.captionLanguage },
                    set: { value in model.configStore.update { $0.captionLanguage = value } }
                )) {
                    ForEach(OutputLanguage.allCases.filter(\.isTranslation), id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!config.captionTranslate)
                Toggle("边听边翻译", isOn: Binding(
                    get: { config.captionLiveTranslate },
                    set: { value in model.configStore.update { $0.captionLiveTranslate = value } }
                ))
                .disabled(!config.captionTranslate)
            } header: {
                Text("翻译")
            } footer: {
                Text(!config.ai.isConfigured ? String(localized: "需要先在\"配置 AI\"里选好服务。")
                     : config.captionLiveTranslate
                     ? String(localized: "用\"配置 AI\"里的服务翻译，译文显示在原文下面。边听边翻译时，正在说的这句也会先翻出来，随说话内容更新，会多调用几次 AI 服务。")
                     : String(localized: "每句说完后，用\"配置 AI\"里的服务翻译，译文显示在原文下面。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // 正在播放声音的应用随时会变，定期刷新
            while !Task.isCancelled {
                let playing = AudioProcesses.playingApps()
                if playing != apps { apps = playing }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 正在发声的应用，加上已经选中但现在没有声音的那个。
    private var sourceChoices: [AudioSourceApp] {
        let current = config.listenSource
        guard !current.isEmpty, !apps.contains(where: { $0.bundleID == current }) else { return apps }
        return [AudioSourceApp(bundleID: current, name: AudioProcesses.name(of: current))] + apps
    }
}

/// 识别模型：默认 SenseVoice，也可以换成其他模型。
struct ModelSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                SpeechModelList(model: model)
            } footer: {
                Text("所有模型都在这台 Mac 上运行，声音不会上传。还没下载的模型，下载完成后自动换用，期间继续用当前的模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
