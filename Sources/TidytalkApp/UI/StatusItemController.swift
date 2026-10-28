import AppKit
import Observation
import TidytalkCore

/// 菜单栏图标：录音、处理中、未就绪时切换图标。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// 点菜单项粘贴前等菜单关掉、焦点回到原来的输入框。
    private static let menuCloseDelay: Duration = .milliseconds(150)
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    var onOpenSettings: (() -> Void)?
    /// 用另一种整理模式或输出语言重新整理一条最近记录。
    var onReprocess: ((HistoryEntry, CleanupStyle, OutputLanguage) -> Void)?
    var onToggleListening: (() -> Void)?
    /// 打开资料库里的说话记录
    var onOpenLibrary: (() -> Void)?
    var onPasteRecentCaptions: (() -> Void)?
    var onWillPasteHistory: (() -> Void)?
    var onOpenTranscriber: (() -> Void)?
    var onToggleMeeting: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?

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
        // 会议录音时在图标右上角加一个红点，收听电脑声音（实时字幕）时加一个橙点
        let dot: NSColor? = model.phase == .recording ? nil
            : model.meetingRecording ? .systemRed : model.isListening ? .systemOrange : nil
        button.image = dot.flatMap { color in image.map { Self.withDot($0, color: color) } } ?? image
        button.contentTintColor = tint
        button.toolTip = model.phase == .recording ? String(localized: "Tidytalk：正在录音")
            : model.meetingRecording ? String(localized: "Tidytalk：正在记录会议")
            : String(localized: "Tidytalk：\(model.readinessDescription)")
    }

    /// 在模板图标上叠一个彩色圆点。图片在绘制时才渲染，图标颜色跟随菜单栏的深浅色。
    private static func withDot(_ symbol: NSImage, color: NSColor) -> NSImage {
        let size = NSSize(width: max(18, symbol.size.width + 4), height: max(16, symbol.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = NSRect(x: (rect.width - symbol.size.width) / 2 - 1,
                                    y: (rect.height - symbol.size.height) / 2,
                                    width: symbol.size.width, height: symbol.size.height)
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: symbolRect)
            let dot: CGFloat = 6
            let dotRect = NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Tidytalk"
        return image
    }

    /// 菜单只放操作和最近的结果，开关和设置项都在设置里（每个选项只在一处）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshPermissions()
        model.configStore.reload()
        menu.removeAllItems()

        let status = NSMenuItem(title: model.readinessDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        // 配置文件格式错误时，设置改动不会保存（免得覆盖用户的文件），在最上面提示并给出修改入口
        if model.configStore.loadError != nil {
            let broken = item(String(localized: "⚠️ 配置文件格式错误，设置改动不会保存。点此打开修改"), #selector(openConfigFile))
            menu.addItem(broken)
        }

        // 开始各个功能
        menu.addItem(.separator())
        let listen = item(model.isListening ? String(localized: "停止实时字幕") : String(localized: "开始实时字幕"),
                          #selector(toggleListening), key: "c")
        listen.keyEquivalentModifierMask = [.control, .option]
        listen.image = Self.symbol("captions.bubble")
        menu.addItem(listen)
        if model.isListening {
            let pasteRecent = item(String(localized: "粘贴刚才那段"), #selector(pasteRecentCaptions), key: "v")
            pasteRecent.keyEquivalentModifierMask = [.control, .option]
            pasteRecent.image = Self.symbol("text.insert")
            menu.addItem(pasteRecent)
        }
        let meeting = item(model.meetingRecording ? String(localized: "结束会议记录") : String(localized: "开始会议记录"),
                           #selector(toggleMeeting), key: "m")
        meeting.keyEquivalentModifierMask = [.control, .option]
        meeting.image = Self.symbol("person.2")
        menu.addItem(meeting)
        let transcribe = item(String(localized: "转写文件或链接…"), #selector(openTranscriber))
        transcribe.image = Self.symbol("waveform")
        menu.addItem(transcribe)

        // 最近的结果：点一条展开粘贴、拷贝、重新整理
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "最近的结果")))
        let entries = model.history.prefix(Self.recentLimit)
        if entries.isEmpty {
            let empty = NSMenuItem(title: String(localized: "还没有说话记录"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in entries { menu.addItem(recentItem(entry)) }
        let all = item(String(localized: "显示全部记录…"), #selector(openLibrary))
        all.image = Self.symbol("books.vertical")
        menu.addItem(all)

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "打开 Tidytalk"), #selector(openMainWindow), key: "o"))
        menu.addItem(item(String(localized: "设置…"), #selector(openSettings), key: ","))
        if UpdateChecker.isConfigured {
            menu.addItem(item(String(localized: "检查更新…"), #selector(checkForUpdates)))
        }
        menu.addItem(helpItem())
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "退出 Tidytalk"), #selector(quit), key: "q"))
    }

    private static let recentLimit = 3

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// 一条最近的结果：子菜单里可以重新粘贴、拷贝、拷贝识别原文、换一种方式整理、加入词库。
    private func recentItem(_ entry: HistoryEntry) -> NSMenuItem {
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
        actions.addItem(.separator())
        actions.addItem(historyAction(String(localized: "加入词库…"), #selector(addToVocabulary(_:)), entry.transcript))
        actions.addItem(.separator())
        let stamp = NSMenuItem(title: entry.date.formatted(date: .omitted, time: .shortened), action: nil, keyEquivalent: "")
        stamp.isEnabled = false
        actions.addItem(stamp)
        entryItem.submenu = actions
        return entryItem
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleListening() { onToggleListening?() }
    @objc private func openTranscriber() { onOpenTranscriber?() }
    @objc private func toggleMeeting() { onToggleMeeting?() }
    @objc private func openMainWindow() { onOpenMainWindow?() }
    @objc private func openLibrary() { onOpenLibrary?() }
    /// 菜单关闭后焦点回到原来的输入框，再粘贴进去。
    @objc private func pasteRecentCaptions() {
        Task {
            try? await Task.sleep(for: Self.menuCloseDelay)
            onPasteRecentCaptions?()
        }
    }

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
        onWillPasteHistory?()
        Task {
            try? await Task.sleep(for: Self.menuCloseDelay)
            await PasteService.paste(text)
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

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

    @objc private func openConfigFile() { model.configStore.openInEditor() }

    @objc private func openSettings() { onOpenSettings?() }

    /// 帮助：官网上的使用指南和隐私说明。
    private func helpItem() -> NSMenuItem {
        let help = NSMenuItem(title: String(localized: "帮助"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(item(String(localized: "使用指南"), #selector(openGuide)))
        submenu.addItem(item(String(localized: "隐私说明"), #selector(openPrivacy)))
        help.submenu = submenu
        return help
    }

    @objc private func openGuide() { HelpLinks.open(HelpLinks.guide) }
    @objc private func openPrivacy() { HelpLinks.open(HelpLinks.privacy) }
    @objc private func quit() { NSApp.terminate(nil) }
}
