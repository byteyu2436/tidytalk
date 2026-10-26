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
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?
    private let navigation = MainNavigation()
    private let settingsNavigation = SettingsNavigation()
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
        indicator = IndicatorPanel(model: model)
        controller = DictationController(model: model, indicator: indicator)
        setUpListening()
        setUpMeetings()
        statusItem = StatusItemController(model: model)
        statusItem.onToggleListening = { [weak self] in self?.toggleCaptions() }
        statusItem.onToggleMeeting = { [weak self] in self?.meetings.toggle() }
        statusItem.onListenSourceChanged = { [weak self] in self?.listener.restartIfRunning() }
        statusItem.onSetCaptionTranslation = { [weak self] in self?.listener.setTranslation($0) }
        statusItem.onPasteRecentCaptions = { [weak self] in self?.listener.pasteRecent() }
        statusItem.onWillPasteHistory = { [weak self] in self?.controller.stopCorrectionWatch() }
        statusItem.onOpenTranscriber = { [weak self] in self?.showMainWindow(.transcribe) }
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
            let stillOpen = [self.onboardingWindow, self.settingsWindow, self.mainWindow].contains {
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
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: String(localized: "设置…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: String(localized: "退出 Tidytalk"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Tidytalk", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: String(localized: "编辑"))
        edit.addItem(withTitle: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: String(localized: "编辑"), action: nil, keyEquivalent: "").submenu = edit

        return main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = Self.makeOnboardingWindow(model: model) { [weak self] in
                self?.onboardingWindow?.close()
            }
            onboardingWindow?.delegate = self
        }
        present(onboardingWindow)
    }

    /// 主窗口：会议、转写、最近记录、词库。`section` 为 nil 时保留上次看的页。
    private func showMainWindow(_ section: MainNavigation.Section? = nil) {
        if mainWindow == nil {
            // 转写和说话输入、实时字幕共用识别模型
            transcriber = TranscribeController(model: model, store: TranscriptionStore()) { [weak self] in
                await self?.controller.readyRecognizer()
            }
            let window = MainWindow.make(model: model, meetings: meetings, transcriber: transcriber,
                                         navigation: navigation) { [weak self] page in self?.showSettings(page) }
            window.delegate = self
            mainWindow = window
        }
        if let section { navigation.section = section }
        present(mainWindow)
    }

    private func showSettings(_ page: MainNavigation.SettingsPage? = nil) {
        if settingsWindow == nil {
            let window = SettingsWindow.make(model: model, meetingStore: meetings.store, navigation: settingsNavigation,
                                             onOpenOnboarding: { [weak self] in self?.showOnboarding() },
                                             onToggleListening: { [weak self] in self?.listener.toggle() },
                                             onListenSourceChanged: { [weak self] in self?.listener.restartIfRunning() },
                                             onSetCaptionTranslation: { [weak self] in self?.listener.setTranslation($0) })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if let page { settingsNavigation.page = page }
        present(settingsWindow)
    }

    static func makeOnboardingWindow(model: AppModel, step: OnboardingView.Step? = nil,
                                     onFinish: @escaping () -> Void = {}) -> NSWindow {
        let view = OnboardingView(model: model, onFinish: onFinish, initialStep: step)
        let window = FocusFriendlyWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        // 和主窗口一样隐藏标题栏，标题由侧边栏的欢迎语显示
        AppShell<EmptyView, EmptyView>.configure(window, title: String(localized: "欢迎使用 Tidytalk"))
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
