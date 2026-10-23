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
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var transcribeWindow: NSWindow?
    private var transcriber: TranscribeController!
    /// 最近一个在前台的其他应用：通过网址被打开时 Tidytalk 可能会被激活，要把焦点还回去，才能粘贴到原来的输入框。
    private var lastFrontApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        indicator = IndicatorPanel(model: model)
        controller = DictationController(model: model, indicator: indicator)
        setUpListening()
        statusItem = StatusItemController(model: model)
        statusItem.onToggleListening = { [weak self] in self?.listener.toggle() }
        statusItem.onListenSourceChanged = { [weak self] in self?.listener.restartIfRunning() }
        statusItem.onSetCaptionTranslation = { [weak self] in self?.listener.setTranslation($0) }
        statusItem.onPasteRecentCaptions = { [weak self] in self?.listener.pasteRecent() }
        statusItem.onOpenTranscriber = { [weak self] in self?.showTranscriber() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onReprocess = { [weak self] entry, style, language in
            self?.controller.reprocess(entry, style: style, language: language)
        }

        controller.start()
        observeAccessibility()
        observeFrontApp()
        UpdateChecker.checkInBackgroundIfNeeded(enabled: model.configStore.config.autoUpdateCheck)

        if !model.onboardingCompleted || model.readiness != .ready {
            showOnboarding()
        }
    }

    /// 应用已在运行时再次打开（Finder、启动台、Spotlight 或点击 Dock 图标）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.onboardingCompleted || model.readiness != .ready {
            showOnboarding()
        } else {
            showSettings()
        }
        return false
    }

    /// 窗口打开期间在 Dock 中显示图标，切到其他应用后也能找回来；
    /// 所有窗口关闭后恢复为只在菜单栏显示。
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = [self.onboardingWindow, self.settingsWindow, self.transcribeWindow].contains {
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
        listener.onStart = { [weak self] in self?.captions.show() }
        listener.onStop = { [weak self] in self?.captions.close() }
        // 正在说话输入时不打断，提示只在空闲时显示
        listener.onError = { [weak self] message in
            guard let self, self.model.phase == .idle else { return }
            self.controller.showMessage(message)
        }
        listener.onPaste = { [weak self] text in self?.controller.pasteCaptions(text) }
        listenHotKey = GlobalHotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in
            self?.listener.toggle()
        }
        // ⌃⌥V：粘贴刚才那段
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
            case .captions(.toggle): listener.toggle()
            case .captions(.start): if !model.isListening { listener.toggle() }
            case .captions(.stop): if model.isListening { listener.stop() }
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

    /// 转写文件或链接，和说话输入、实时字幕共用识别模型。
    private func showTranscriber() {
        if transcribeWindow == nil {
            transcriber = TranscribeController(model: model) { [weak self] in await self?.controller.readyRecognizer() }
            let window = TranscribeWindow.make(controller: transcriber)
            window.delegate = self
            transcribeWindow = window
        }
        present(transcribeWindow)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindow.make(model: model,
                                             onOpenOnboarding: { [weak self] in self?.showOnboarding() },
                                             onToggleListening: { [weak self] in self?.listener.toggle() },
                                             onListenSourceChanged: { [weak self] in self?.listener.restartIfRunning() },
                                             onSetCaptionTranslation: { [weak self] in self?.listener.setTranslation($0) })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    static func makeOnboardingWindow(model: AppModel, step: OnboardingView.Step? = nil,
                                     onFinish: @escaping () -> Void = {}) -> NSWindow {
        let view = OnboardingView(model: model, onFinish: onFinish, initialStep: step)
        let window = FocusFriendlyWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "欢迎使用 Tidytalk")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // 内容延伸到标题栏下面，标题由页面自己的大标题显示，避免两行标题重叠
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
