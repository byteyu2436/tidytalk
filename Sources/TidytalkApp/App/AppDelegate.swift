import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TidytalkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var indicator: IndicatorPanel!
    private var controller: DictationController!
    private var statusItem: StatusItemController!
    private var listener: ListenController!
    private var captions: CaptionPanel!
    private var listenHotKey: GlobalHotKey?
    private var pasteHotKey: GlobalHotKey?
    private var meetingHotKey: GlobalHotKey?
    private var meetings: MeetingController!
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?
    private let navigation = MainNavigation()
    private var transcriber: TranscribeController!
    /// 最近一个在前台的其他应用：通过网址被打开时 Tidytalk 可能会被激活，要把焦点还回去，才能粘贴到原来的输入框。
    private var lastFrontApp: NSRunningApplication?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 读取别的应用的输入框时最多等 0.5 秒，目标应用卡死时 Tidytalk 不跟着卡
        Accessibility.configure()
        // 本地词库纠错时，真实存在的英文单词不做模糊匹配（"discard"不改成"Discord"）
        VocabularyMatcher.dictionaryWordCheck = { word in
            // NSSpellChecker 只能在主线程上用；说话输入和字幕的整理都在主线程上调用
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        NSApp.mainMenu = makeMainMenu()
        model.configStore.config.appearance.apply()
        indicator = IndicatorPanel(model: model)
        controller = DictationController(model: model, indicator: indicator)
        setUpListening()
        setUpMeetings()
        statusItem = StatusItemController(model: model)
        statusItem.onToggleListening = { [weak self] in self?.toggleCaptions() }
        statusItem.onToggleMeeting = { [weak self] in self?.meetings.toggle() }
        statusItem.onOpenLibrary = { [weak self] in
            self?.navigation.libraryFilter = .dictation
            self?.showMainWindow(.library)
        }
        statusItem.onPasteRecentCaptions = { [weak self] in self?.listener.pasteRecent() }
        statusItem.onWillPasteHistory = { [weak self] in self?.controller.stopCorrectionWatch() }
        statusItem.onOpenTranscriber = { [weak self] in
            self?.showMainWindow(.transcribe)
            self?.navigation.linkFieldRequest += 1
        }
        statusItem.onOpenMainWindow = { [weak self] in self?.showMainWindow() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onReprocess = { [weak self] entry, style, language in
            self?.controller.reprocess(entry, style: style, language: language)
        }

        controller.start()
        observeAccessibility()
        observeFrontApp()
        UpdateChecker.checkInBackgroundIfNeeded(enabled: model.configStore.config.autoUpdateCheck)
        // 菜单栏应用常常几周不退出：每 6 小时看一次，满一天才真正检查
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UpdateChecker.checkInBackgroundIfNeeded(enabled: self.model.configStore.config.autoUpdateCheck)
            }
        }

        if !model.onboardingCompleted || model.readiness != .ready {
            showOnboarding()
        }
    }

    /// 退出前收尾：正在等待恢复的剪贴板立即恢复，免得用户原来复制的内容丢失；停止录音和字幕。
    func applicationWillTerminate(_ notification: Notification) {
        // 正在记录的会议：停下并写完录音文件，下次启动时接着处理
        meetings.stop()
        PasteService.finishPending()
        controller.externalCancel()
        if model.isListening { listener.stop() }
    }

    /// 应用已在运行时再次打开（Finder、启动台、Spotlight 或点击 Dock 图标）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.onboardingCompleted || model.readiness != .ready {
            showOnboarding()
        } else {
            showMainWindow()
        }
        return false
    }

    /// 窗口打开期间在 Dock 中显示图标，切到其他应用后也能找回来；
    /// 所有窗口关闭后恢复为只在菜单栏显示。
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = [self.onboardingWindow, self.mainWindow].contains {
                $0 != nil && $0 !== closing && $0!.isVisible
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// 实时字幕：⌃⌥C 开始或停止收听，字幕条上的 ✕ 也是停止收听；⌃⌥V 或点字幕条上的句子，把听到的话粘贴出来。
    private func setUpListening() {
        listener = ListenController(model: model) { [weak self] in await self?.controller.readyRecognizer() }
        captions = CaptionPanel(model: model)
        captions.onPause = { [weak self] in self?.listener.setPaused($0) }
        captions.onTranslate = { [weak self] in self?.listener.setTranslation($0) }
        captions.onPasteFrom = { [weak self] in self?.listener.paste(from: $0) }
        captions.onClose = { [weak self] in self?.listener.stop() }
        // ⌃⌥V 只在字幕打开期间占用，其他时候留给别的应用
        listener.onStart = { [weak self] in
            self?.captions.show()
            self?.registerPasteHotKey()
        }
        listener.onStop = { [weak self] in
            self?.captions.close()
            self?.pasteHotKey?.unregister()
            self?.pasteHotKey = nil
        }
        // 正在说话输入时不打断，提示只在空闲时显示
        listener.onError = { [weak self] message in
            guard let self, self.model.phase == .idle else { return }
            self.controller.showMessage(message)
        }
        listener.onPaste = { [weak self] text in self?.controller.pasteCaptions(text) }
        listenHotKey = GlobalHotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggleCaptions()
        }
    }

    /// 会议记录和实时字幕都要收听电脑的声音，不能同时开。
    private func toggleCaptions() {
        if !model.isListening, model.meetingRecording {
            controller.showMessage(String(localized: "正在记录会议，结束后才能打开实时字幕"))
            return
        }
        listener.toggle()
    }

    /// 会议记录：⌃⌥M 开始或结束；录完自动分说话人、精修文字。
    private func setUpMeetings() {
        let recognizer: () async -> (any SpeechTranscribing)? = { [weak self] in await self?.controller.readyRecognizer() }
        let store = MeetingStore()
        let processor = MeetingProcessor(model: model, store: store, recognizer: recognizer)
        meetings = MeetingController(model: model, store: store, processor: processor, recognizer: recognizer)
        meetings.onStart = { [weak self] in
            guard let self else { return }
            if model.isListening {
                listener.stop()
                controller.showMessage(String(localized: "已关闭实时字幕：会议记录会同时收听电脑的声音"))
            }
        }
        meetings.onError = { [weak self] message in self?.controller.showMessage(message) }
        meetingHotKey = GlobalHotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { [weak self] in
            self?.meetings.toggle()
        }
        // 上次没录完或没处理完就退出了：录音文件还在，接着处理
        processor.resumeInterrupted()
    }

    /// ⌃⌥V：粘贴刚才那段。
    private func registerPasteHotKey() {
        guard pasteHotKey == nil else { return }
        pasteHotKey = GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
            self?.listener.pasteRecent()
        }
    }

    // MARK: - 外部控制

    /// tidytalk://toggle、tidytalk://captions 等网址，见 `ExternalCommand`。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = ExternalCommand(url: url) else { continue }
            returnFocus()
            switch command {
            case .toggle: controller.externalToggle()
            case .start: controller.externalStart()
            case .stop: controller.externalStop()
            case .cancel: controller.externalCancel()
            case .captions(.toggle): toggleCaptions()
            case .captions(.start): if !model.isListening { toggleCaptions() }
            case .captions(.stop): if model.isListening { listener.stop() }
            case .meeting(.toggle): meetings.toggle()
            case .meeting(.start): meetings.start()
            case .meeting(.stop): meetings.stop()
            }
        }
    }

    private func observeFrontApp() {
        lastFrontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != .current else { return }
            MainActor.assumeIsolated { self?.lastFrontApp = app }
        }
    }

    /// 被网址激活、又没有打开的窗口时，把焦点还给原来的应用。
    private func returnFocus() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        lastFrontApp?.activate()
    }

    /// 授权辅助功能后立即开始监听按键，无需重启应用。
    private func observeAccessibility() {
        withObservationTracking {
            _ = model.accessibilityGranted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.controller.startHotkeysIfPossible()
                self?.observeAccessibility()
            }
        }
        // 在没有打开任何窗口时也定期检查一次
        Task { [weak self] in
            while let self, !self.model.accessibilityGranted {
                try? await Task.sleep(for: .seconds(2))
                self.model.refreshPermissions()
            }
        }
    }

    /// 窗口里的输入框要靠主菜单才能响应 Cmd+C / Cmd+V 等快捷键。
    /// 打开主窗口时屏幕顶部的应用菜单：Tidytalk、文件、编辑、显示、窗口、帮助，常用操作都有快捷键。
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
        }

        let appMenu = NSMenu()
        add(appMenu, String(localized: "关于 Tidytalk"), #selector(openAbout), target: self)
        if UpdateChecker.isConfigured {
            add(appMenu, String(localized: "检查更新…"), #selector(checkForUpdatesFromMenu), target: self)
        }
        appMenu.addItem(.separator())
        add(appMenu, String(localized: "设置…"), #selector(openSettingsFromMenu), ",", target: self)
        appMenu.addItem(.separator())
        add(appMenu, String(localized: "退出 Tidytalk"), #selector(NSApplication.terminate(_:)), "q")
        main.addItem(withTitle: "Tidytalk", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: String(localized: "文件"))
        add(file, String(localized: "开始或结束会议记录"), #selector(toggleMeetingFromMenu), "m", [.control, .option], target: self)
        add(file, String(localized: "转写文件…"), #selector(transcribeFileFromMenu), "o", target: self)
        add(file, String(localized: "转写链接…"), #selector(transcribeLinkFromMenu), "l", target: self)
        file.addItem(.separator())
        add(file, String(localized: "导出…"), #selector(exportFromMenu), "e", [.command, .shift], target: self)
        add(file, String(localized: "关闭窗口"), #selector(NSWindow.performClose(_:)), "w")
        main.addItem(withTitle: String(localized: "文件"), action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: String(localized: "编辑"))
        add(edit, String(localized: "撤销"), Selector(("undo:")), "z")
        add(edit, String(localized: "重做"), Selector(("redo:")), "Z")
        edit.addItem(.separator())
        add(edit, String(localized: "剪切"), #selector(NSText.cut(_:)), "x")
        add(edit, String(localized: "拷贝"), #selector(NSText.copy(_:)), "c")
        add(edit, String(localized: "粘贴"), #selector(NSText.paste(_:)), "v")
        add(edit, String(localized: "全选"), #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, String(localized: "在资料库里搜索"), #selector(searchFromMenu), "f", target: self)
        main.addItem(withTitle: String(localized: "编辑"), action: nil, keyEquivalent: "").submenu = edit

        // 显示：和侧边栏一样的四页（⌘1–⌘4），返回（⌘[）
        let view = NSMenu(title: String(localized: "显示"))
        for (index, section) in MainNavigation.Section.allCases.enumerated() {
            let item = view.addItem(withTitle: section.title, action: #selector(showSectionFromMenu(_:)),
                                    keyEquivalent: String(index + 1))
            item.target = self
            item.tag = index
        }
        view.addItem(.separator())
        add(view, String(localized: "返回"), #selector(goBackFromMenu), "[", target: self)
        main.addItem(withTitle: String(localized: "显示"), action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: String(localized: "窗口"))
        add(window, String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, String(localized: "缩放"), #selector(NSWindow.performZoom(_:)))
        main.addItem(withTitle: String(localized: "窗口"), action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        // 帮助：官网上的使用指南和隐私说明（设成 helpMenu 后系统会在最上面加搜索框）
        let help = NSMenu(title: String(localized: "帮助"))
        add(help, String(localized: "使用指南"), #selector(openGuide), "?", target: self)
        add(help, String(localized: "键盘快捷键"), #selector(openShortcuts), target: self)
        add(help, String(localized: "隐私说明"), #selector(openPrivacy), target: self)
        help.addItem(.separator())
        add(help, String(localized: "反馈问题…"), #selector(openIssues), target: self)
        main.addItem(withTitle: String(localized: "帮助"), action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help

        return main
    }

    @objc private func openAbout() { showSettings(.about) }
    @objc private func openShortcuts() { showSettings(.shortcuts) }
    @objc private func openIssues() { HelpLinks.open(HelpLinks.issues) }
    @objc private func checkForUpdatesFromMenu() { Task { await UpdateChecker.check(userInitiated: true) } }
    @objc private func toggleMeetingFromMenu() { meetings.toggle() }

    @objc private func showSectionFromMenu(_ sender: NSMenuItem) {
        guard MainNavigation.Section.allCases.indices.contains(sender.tag) else { return }
        showMainWindow(MainNavigation.Section.allCases[sender.tag])
    }

    /// 返回：设置里回到原来的页，详情页回到列表。
    @objc private func goBackFromMenu() {
        if navigation.settings != nil {
            navigation.closeSettings()
        } else {
            navigation.closeRecord()
        }
    }

    /// 导出正在看的会议或转写（详情页里接着弹出存储面板）。
    @objc private func exportFromMenu() {
        guard navigation.meeting != nil || navigation.transcription != nil else { NSSound.beep(); return }
        navigation.exportRequest += 1
    }

    @objc private func searchFromMenu() {
        showMainWindow(.library)
        navigation.searchRequest += 1
    }

    @objc private func transcribeLinkFromMenu() {
        showMainWindow(.transcribe)
        navigation.linkFieldRequest += 1
    }

    /// 选一个音频或视频文件转写，然后打开它的转写详情。
    @objc private func transcribeFileFromMenu() {
        showMainWindow(.transcribe)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let transcriber else { return }
        transcriber.clearFailure()
        if let id = transcriber.transcribe(file: url) { navigation.openTranscription(id) }
    }


    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func openGuide() { HelpLinks.open(HelpLinks.guide) }
    @objc private func openPrivacy() { HelpLinks.open(HelpLinks.privacy) }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = Self.makeOnboardingWindow(model: model) { [weak self] in
                self?.onboardingWindow?.close()
            }
            onboardingWindow?.delegate = self
        }
        present(onboardingWindow)
    }

    /// 主窗口：会议、转写、最近记录、词库，以及设置。`section` 为 nil 时保留上次看的页（包括正在看的设置）。
    private func showMainWindow(_ section: MainNavigation.Section? = nil) {
        if mainWindow == nil {
            // 转写和说话输入、实时字幕共用识别模型
            transcriber = TranscribeController(model: model, store: TranscriptionStore()) { [weak self] in
                await self?.controller.readyRecognizer()
            }
            let settings = SettingsActions(
                onOpenOnboarding: { [weak self] in self?.showOnboarding() },
                onToggleListening: { [weak self] in self?.listener.toggle() },
                onListenSourceChanged: { [weak self] in self?.listener.restartIfRunning() },
                onSetCaptionTranslation: { [weak self] in self?.listener.setTranslation($0) },
                onReprocess: { [weak self] entry, style, language in
                    self?.controller.reprocess(entry, style: style, language: language)
                })
            let window = MainWindow.make(model: model, meetings: meetings, transcriber: transcriber,
                                         navigation: navigation, settings: settings)
            window.delegate = self
            mainWindow = window
        }
        if let section { navigation.show(section) }
        present(mainWindow)
    }

    /// 设置在主窗口里：打开主窗口并切到设置（`page` 为 nil 时回到上次看的设置页）。
    private func showSettings(_ page: MainNavigation.SettingsPage? = nil) {
        navigation.openSettings(page)
        showMainWindow()
    }

    static func makeOnboardingWindow(model: AppModel, step: OnboardingView.Step? = nil,
                                     onFinish: @escaping () -> Void = {}) -> NSWindow {
        let view = OnboardingView(model: model, onFinish: onFinish, initialStep: step)
        let host = NSHostingController(rootView: view)
        // 窗口固定 860×600，不跟着每一步内容的大小变
        host.sizingOptions = []
        let window = FocusFriendlyWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        // 和主窗口一样隐藏标题栏，标题由侧边栏的欢迎语显示
        AppShell<EmptyView, EmptyView>.configure(window, title: String(localized: "欢迎使用 Tidytalk"))
        window.setContentSize(NSSize(width: 860, height: 600))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// 打开窗口并放到最前面。
    ///
    /// 从菜单栏菜单打开时，菜单还没收起、应用刚从"只在菜单栏"切成普通应用，这时请求激活会被系统忽略，
    /// 窗口只在 Dock 里出现图标却不到前面。所以等这一轮事件处理完（菜单收起后）再激活，并强制把窗口放到最前。
    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}
