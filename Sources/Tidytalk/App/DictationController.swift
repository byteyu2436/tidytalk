import AppKit
import TidytalkCore

/// 串起整个流程：按键 → 录音 → 本地识别 → AI 整理（OpenAI 兼容接口）→ 粘贴。
@MainActor
final class DictationController {
    static let minimumDuration: TimeInterval = 0.5
    static let messageDuration: Duration = .seconds(2.5)

    private let model: AppModel
    private let indicator: IndicatorPanel
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()

    private var recognizer: SpeechRecognizer?
    private var recognizerTask: Task<SpeechRecognizer?, Never>?
    private var isProcessing = false
    /// 当前这次录音的用途：说话输入，或语音改写选中的文字。
    private var purpose: HotkeyMonitor.Purpose = .dictation
    private var messageTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(model: AppModel, indicator: IndicatorPanel) {
        self.model = model
        self.indicator = indicator

        hotkeys.onAction = { [weak self] action, purpose in self?.handle(action, purpose) }
        // 刷新界面上的权限状态；重新授权后由 startHotkeysIfPossible 再次开始监听
        hotkeys.onPermissionLost = { [weak model] in model?.refreshPermissions() }
        hotkeys.dictationKey = { [weak model] in model?.configStore.config.hotkey ?? .optionCommand }
        hotkeys.rewriteKey = { [weak model] in model?.configStore.config.activeRewriteHotkey }
        hotkeys.handsFreeEnabled = { [weak model] in model?.configStore.config.handsFree ?? false }
        recorder.onLevel = { [weak self] level in self?.model.pushLevel(level) }
        recorder.onLimitReached = { [weak self] in
            guard let self else { return }
            hotkeys.recordingEndedExternally(purpose)
            finishRecording()
        }
        model.models.onReady = { [weak self] in self?.loadRecognizer() }
    }

    func start() {
        startHotkeysIfPossible()
        loadRecognizer()
    }

    /// 辅助功能授权后才能创建事件监听，权限状态变化时调用。
    func startHotkeysIfPossible() {
        guard model.accessibilityGranted else {
            if hotkeys.isRunning { hotkeys.stop() }
            return
        }
        guard !hotkeys.isRunning else { return }
        hotkeys.start()
    }

    // MARK: - 识别器

    private func loadRecognizer() {
        guard recognizer == nil, recognizerTask == nil, model.models.isReady else { return }
        let directory = model.models.directory
        recognizerTask = Task.detached(priority: .userInitiated) {
            try? SpeechRecognizer(modelDirectory: directory)
        }
        Task {
            let loaded = await recognizerTask?.value
            recognizer = loaded
            recognizerTask = nil
        }
    }

    private func readyRecognizer() async -> SpeechRecognizer? {
        if let recognizer { return recognizer }
        if recognizerTask == nil { loadRecognizer() }
        return await recognizerTask?.value
    }

    // MARK: - 按键动作

    private func handle(_ action: HotkeyStateMachine.Action, _ source: HotkeyMonitor.Purpose) {
        switch action {
        case .startRecording: beginRecording(for: source)
        // 另一个触发键结束或取消时，不影响当前这次录音
        case .finishRecording: if source == purpose { finishRecording() }
        case .cancelRecording: if source == purpose { cancelRecording() }
        case .scheduleHoldTimer, .cancelHoldTimer: break
        }
    }

    private func beginRecording(for source: HotkeyMonitor.Purpose) {
        guard !isProcessing, !recorder.isRecording else {
            hotkeys.recordingEndedExternally(source)
            return
        }
        model.refreshPermissions()
        switch model.readiness {
        case .ready:
            break
        case .needsMicrophone, .needsAccessibility, .modelNotReady:
            hotkeys.recordingEndedExternally(source)
            showMessage(model.readinessDescription)
            return
        }
        let config = model.configStore.config
        if source == .rewrite, !config.ai.isConfigured {
            hotkeys.recordingEndedExternally(source)
            showMessage(String(localized: "请先在设置里配置 AI"))
            return
        }

        if config.sounds { Sounds.start() }
        do {
            model.resetLevels()
            try recorder.start(deviceUID: config.microphone)
        } catch {
            hotkeys.recordingEndedExternally(source)
            showMessage(String(localized: "无法开始录音：\(error.localizedDescription)"))
            return
        }
        purpose = source
        model.indicatorTag = indicatorTag(for: source, config: config)
        model.sparkles = source == .rewrite
        messageTask?.cancel()
        model.phase = .recording
        indicator.show()
        if config.livePreview { startLivePreview() }
    }

    /// 指示器上的模式标签：只转文字（关闭整理或没有配置 AI）时不显示；开启 AI 整理显示"整理"；翻译时显示"译成英文"这类文案；
    /// 语音改写显示"改写"。
    private func indicatorTag(for source: HotkeyMonitor.Purpose, config: AppConfig) -> String? {
        if source == .rewrite { return String(localized: "改写") }
        guard config.cleanupEnabled, config.ai.isConfigured else { return nil }
        return config.outputLanguage.indicatorTag ?? String(localized: "整理")
    }

    private func cancelRecording() {
        guard recorder.isRecording else { return }
        stopLivePreview()
        recorder.cancel()
        hide()
    }

    private func finishRecording() {
        guard recorder.isRecording else { return }
        // 停止刷新预览，但保留已经显示的文字，处理期间继续可见
        previewTask?.cancel()
        let samples = recorder.stop()
        if model.configStore.config.sounds { Sounds.finish() }
        let duration = Double(samples.count) / Double(AudioMath.sampleRate)
        guard duration >= Self.minimumDuration else {
            hide()
            return
        }

        model.phase = .processing
        isProcessing = true
        let source = purpose
        Task {
            await process(samples, for: source)
            isProcessing = false
        }
    }

    // MARK: - 处理

    private func process(_ samples: [Float], for source: HotkeyMonitor.Purpose) async {
        guard let recognizer = await readyRecognizer() else {
            showMessage(String(localized: "语音识别模型加载失败"))
            return
        }

        let transcript = await recognizer.transcribe(samples)
        guard TranscriptCleanup.hasContent(transcript) else {
            showMessage(String(localized: "没有听到内容"))
            return
        }

        // 每次整理前重新读取配置文件，手动修改后无需重启
        model.configStore.reload()
        let config = model.configStore.config

        let prepared = TextPipeline.prepare(transcript, config: config)
        if source == .rewrite {
            await rewriteSelection(instruction: prepared, config: config)
            return
        }
        // 快捷短语：整句话就是某个短语时，直接输出设置好的内容
        if let expansion = Snippets.expansion(for: prepared, in: config.snippets) {
            if await paste(expansion, transcript: prepared, kind: .snippet) { hide() }
            return
        }

        let result = await cleanup(prepared, config: config, style: config.style,
                                   language: config.outputLanguage, enabled: config.cleanupEnabled)
        guard await paste(result.text, transcript: prepared) else { return }

        if let notice = result.notice {
            showMessage(notice)
        } else {
            hide()
        }
    }

    /// 一次整理的结果：要粘贴的文字，以及需要提示用户的信息（整理失败时为原文和失败原因）。
    private struct CleanupResult {
        var text: String
        var notice: String?
        var succeeded: Bool { notice == nil }
    }

    private func cleanup(_ prepared: String, config: AppConfig, style: CleanupStyle,
                         language: OutputLanguage, enabled: Bool) async -> CleanupResult {
        var output = prepared
        var notice: String?
        // 实际输出的语言：翻译失败回退原文时仍是原文的语言
        var outputLanguage = OutputLanguage.original
        let failure = language.isTranslation ? String(localized: "翻译失败，已粘贴原文") : String(localized: "整理失败，已粘贴原文")
        if enabled {
            if model.configStore.loadError != nil {
                notice = String(localized: "配置文件格式错误，已粘贴原文")
            } else if !config.ai.isConfigured {
                // 没有配置 AI 时就是只转文字，直接粘贴识别结果，不打扰用户
            } else {
                do {
                    let cleaned = try await ChatCompletionClient(config: config.ai)
                        .cleanup(prepared, style: style, vocabulary: config.vocabulary, language: language,
                                 level: config.cleanupLevel, rules: config.customRules)
                    if let valid = TranscriptCleanup.validate(raw: prepared, cleaned: cleaned, language: language,
                                                             level: config.cleanupLevel) {
                        output = valid
                        outputLanguage = language
                    } else {
                        notice = failure
                    }
                } catch {
                    notice = failure
                }
            }
        } else if language.isTranslation {
            // 翻译依赖 AI 整理
            notice = String(localized: "未开启整理文字，已粘贴原文")
        }
        return CleanupResult(text: TextPipeline.finish(output, config: config, style: style, language: outputLanguage),
                             notice: notice)
    }

    // MARK: - 重新整理

    /// 用另一种整理模式或输出语言，重新整理最近记录里的一条，粘贴到当前的输入框。
    func reprocess(_ entry: HistoryEntry, style: CleanupStyle, language: OutputLanguage) {
        guard entry.canReprocess, !isProcessing, !recorder.isRecording else { return }
        model.configStore.reload()
        let config = model.configStore.config
        guard model.configStore.loadError == nil, config.ai.isConfigured else {
            showMessage(String(localized: "请先在设置里配置 AI"))
            return
        }
        isProcessing = true
        messageTask?.cancel()
        model.sparkles = false
        model.indicatorTag = language.indicatorTag ?? String(localized: "整理")
        model.phase = .processing
        indicator.show()
        Task {
            // 等菜单关闭、焦点回到原来的输入框
            try? await Task.sleep(for: .milliseconds(150))
            let result = await cleanup(entry.transcript, config: config, style: style, language: language, enabled: true)
            if result.succeeded {
                if await paste(result.text, transcript: entry.transcript) { hide() }
            } else {
                showMessage(String(localized: "重新整理失败，没有粘贴"))
            }
            isProcessing = false
        }
    }

    /// 语音改写：读取选中的文字，按说出的要求改写后替换。
    private func rewriteSelection(instruction: String, config: AppConfig) async {
        guard let selection = await SelectionReader.selectedText() else {
            showMessage(String(localized: "请先选中要改写的文字"))
            return
        }
        do {
            let output = try await ChatCompletionClient(config: config.ai)
                .rewrite(selection: selection, instruction: instruction, vocabulary: config.vocabulary,
                         rules: config.customRules)
            guard let rewritten = RewritePrompt.validate(selection: selection, rewritten: output) else {
                showMessage(String(localized: "改写失败，原文未改动"))
                return
            }
            let finalText = TextPipeline.finish(rewritten, config: config, style: .standard)
            // 选中的文字仍处于选中状态，粘贴即替换
            guard await paste(finalText, transcript: String(localized: "改写：\(instruction)"), kind: .rewrite) else { return }
            hide()
        } catch {
            showMessage(String(localized: "改写失败，原文未改动"))
        }
    }

    /// 粘贴并记入最近记录。没有辅助功能权限时提示并返回 false。
    ///
    /// 当前焦点确定不是输入框时（例如在桌面、列表上），不模拟粘贴，而是把结果留在剪贴板里，
    /// 提示用户自己粘贴到想要的地方，并返回 false。
    @discardableResult
    private func paste(_ text: String, transcript: String, kind: HistoryEntry.Kind = .dictation) async -> Bool {
        model.refreshPermissions()
        guard model.accessibilityGranted else {
            showMessage(String(localized: "需要授权辅助功能才能粘贴"))
            return false
        }
        model.recordHistory(HistoryEntry(date: Date(), transcript: transcript, output: text, kind: kind))
        if FocusInspector.focusedInput() == .notEditable {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showMessage(String(localized: "已拷贝到剪贴板"))
            return false
        }
        await PasteService.paste(text)
        return true
    }

    // MARK: - 指示器

    private func showMessage(_ text: String) {
        messageTask?.cancel()
        stopLivePreview()
        model.sparkles = false
        model.phase = .message(text)
        indicator.show()
        messageTask = Task {
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        messageTask?.cancel()
        stopLivePreview()
        model.phase = .idle
        indicator.hide()
    }

    // MARK: - 实时预览

    private static let previewInterval: Duration = .milliseconds(600)

    /// 录音期间每隔一小段时间识别一次最新的音频，显示在胶囊下方。只是预览，最终结果仍在松开后整段识别。
    private func startLivePreview() {
        stopLivePreview()
        guard let recognizer else { return }   // 模型还没加载好时不预览
        let engine = LivePreviewEngine(recognizer: recognizer)
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.previewInterval)
                guard let self, !Task.isCancelled, recorder.isRecording else { return }
                guard let raw = await engine.update(with: recorder.recordedSamples()),
                      !Task.isCancelled, recorder.isRecording else { continue }
                let text = TextPipeline.prepare(raw, config: model.configStore.config)
                guard TranscriptCleanup.hasContent(text) else { continue }
                model.livePreview = text
                if !model.showsLivePreview { model.showsLivePreview = true }
            }
        }
    }

    private func stopLivePreview() {
        previewTask?.cancel()
        previewTask = nil
        model.livePreview = ""
        if model.showsLivePreview { model.showsLivePreview = false }
    }
}
