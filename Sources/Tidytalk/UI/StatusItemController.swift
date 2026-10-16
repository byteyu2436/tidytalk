import AppKit
import Observation
import TidytalkCore

/// 菜单栏图标：录音、处理中、未就绪时切换图标。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    var onOpenSettings: (() -> Void)?
    /// 用另一种整理模式或输出语言重新整理一条最近记录。
    var onReprocess: ((HistoryEntry, CleanupStyle, OutputLanguage) -> Void)?
    var onOpenOnboarding: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        observe()
    }

    private func observe() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?) = switch model.phase {
        case .recording: ("mic.fill", .systemRed)
        case .processing: ("ellipsis.circle", nil)
        case .idle, .message:
            model.readiness == .ready ? ("waveform", nil) : ("exclamationmark.triangle", nil)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tidytalk")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = model.phase == .recording ? String(localized: "Tidytalk：正在录音") : String(localized: "Tidytalk：\(model.readinessDescription)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshPermissions()
        model.configStore.reload()
        menu.removeAllItems()

        let status = NSMenuItem(title: model.readinessDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let cleanup = NSMenuItem(title: String(localized: "整理文字"), action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = model.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)

        // 输出语言：翻译依赖 AI 整理，关闭整理时不可选
        let current = model.configStore.config.outputLanguage
        let languageMenu = NSMenu()
        for language in OutputLanguage.allCases {
            let entry = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = language == current ? .on : .off
            entry.isEnabled = model.cleanupEnabled
            languageMenu.addItem(entry)
            if language == .original { languageMenu.addItem(.separator()) }
        }
        let languageItem = NSMenuItem(title: String(localized: "输出语言：\(current.title)"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        if model.configStore.config.history {
            menu.addItem(.separator())
            menu.addItem(historyItem())
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "设置…"), #selector(openSettings), key: ","))
        menu.addItem(item(String(localized: "设置引导…"), #selector(openOnboarding)))
        if UpdateChecker.isConfigured {
            menu.addItem(item(String(localized: "检查更新…"), #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "退出 Tidytalk"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// "最近记录"子菜单：每条可以重新粘贴、拷贝，或拷贝识别原文。
    private func historyItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "最近记录"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let entries = model.history.prefix(Self.historyMenuLimit)
        if entries.isEmpty {
            let empty = NSMenuItem(title: String(localized: "暂无记录"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        for entry in entries {
            let entryItem = NSMenuItem(title: Self.preview(entry.output), action: nil, keyEquivalent: "")
            entryItem.toolTip = entry.output
            let actions = NSMenu()
            actions.addItem(historyAction(String(localized: "粘贴"), #selector(pasteHistory(_:)), entry.output))
            actions.addItem(historyAction(String(localized: "拷贝"), #selector(copyHistory(_:)), entry.output))
            if entry.transcript != entry.output {
                actions.addItem(historyAction(String(localized: "拷贝识别原文"), #selector(copyHistory(_:)), entry.transcript))
            }
            if entry.canReprocess {
                actions.addItem(reprocessItem(for: entry))
            }
            actions.addItem(historyAction(String(localized: "加入词库…"), #selector(addToVocabulary(_:)), entry.transcript))
            actions.addItem(.separator())
            let stamp = NSMenuItem(title: time.string(from: entry.date), action: nil, keyEquivalent: "")
            stamp.isEnabled = false
            actions.addItem(stamp)
            entryItem.submenu = actions
            submenu.addItem(entryItem)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: String(localized: "清空记录"), action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !entries.isEmpty
        submenu.addItem(clear)
        let note = NSMenuItem(title: String(localized: "退出后清空"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        item.submenu = submenu
        return item
    }

    private static let historyMenuLimit = 10

    /// 选中的最近记录和要用的整理方式。
    private final class ReprocessChoice: NSObject {
        let entry: HistoryEntry
        let style: CleanupStyle
        let language: OutputLanguage

        init(entry: HistoryEntry, style: CleanupStyle, language: OutputLanguage) {
            self.entry = entry
            self.style = style
            self.language = language
        }
    }

    /// "重新整理"子菜单：四种整理模式（保持原文语言），以及翻译成各种语言（使用当前的整理模式）。
    private func reprocessItem(for entry: HistoryEntry) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "重新整理"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for style in CleanupStyle.allCases {
            submenu.addItem(reprocessChoice(style.title, ReprocessChoice(entry: entry, style: style, language: .original)))
        }
        submenu.addItem(.separator())
        let style = model.configStore.config.style
        for language in OutputLanguage.allCases where language.isTranslation {
            let title = language.indicatorTag ?? language.title
            submenu.addItem(reprocessChoice(title, ReprocessChoice(entry: entry, style: style, language: language)))
        }
        item.submenu = submenu
        return item
    }

    private func reprocessChoice(_ title: String, _ choice: ReprocessChoice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(reprocess(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        return item
    }

    @objc private func reprocess(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ReprocessChoice else { return }
        onReprocess?(choice.entry, choice.style, choice.language)
    }

    private static func preview(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 30 ? String(line.prefix(30)) + "…" : line
    }

    private func historyAction(_ title: String, _ action: Selector, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = text
        return item
    }

    /// 菜单关闭后焦点回到原来的输入框，再粘贴进去。
    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await PasteService.paste(text)
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory() { model.clearHistory() }

    @objc private func checkForUpdates() {
        Task { await UpdateChecker.check(userInitiated: true) }
    }

    /// 把识别错的词加入替换表，可同时加入常用词。
    @objc private func addToVocabulary(_ sender: NSMenuItem) {
        guard let transcript = sender.representedObject as? String else { return }
        let wrong = NSTextField(string: "")
        wrong.placeholderString = String(localized: "识别成（例如 克劳德）")
        let right = NSTextField(string: "")
        right.placeholderString = String(localized: "正确写法（例如 Claude）")
        let alsoTerm = NSButton(checkboxWithTitle: String(localized: "同时加入常用词"), target: nil, action: nil)
        alsoTerm.state = .on
        let stack = NSStackView(views: [wrong, right, alsoTerm])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for field in [wrong, right] { field.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 80)

        let alert = NSAlert()
        alert.messageText = String(localized: "加入词库")
        alert.informativeText = String(localized: "识别结果：\(transcript)\n\n以后识别出左边的写法时，替换成右边的写法。")
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "加入"))
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        alert.window.initialFirstResponder = wrong
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let from = wrong.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = right.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }
        model.configStore.update { config in
            if !from.isEmpty, from != to { config.replacements[from] = to }
            if alsoTerm.state == .on, !config.vocabulary.contains(to) { config.vocabulary.append(to) }
        }
    }

    @objc private func toggleCleanup() { model.cleanupEnabled.toggle() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = OutputLanguage(rawValue: raw) else { return }
        model.configStore.update { $0.outputLanguage = language }
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openOnboarding() { onOpenOnboarding?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
