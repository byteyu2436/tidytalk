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
    private let corrections = CorrectionWatcher()

    private let recognizers: RecognizerStore
    private var isProcessing = false
    /// 当前这次录音的用途：说话输入，或语音改写选中的文字。
    private var purpose: HotkeyMonitor.Purpose = .dictation
    private var messageTask: Task<Void, Never>?
    /// 录音期间的识别：边录边识别和实时预览（见 `LiveTranscription`）。
    private var live: LiveTranscription?
    private var liveTask: Task<Void, Never>?
    private static let liveInterval: Duration = .milliseconds(600)
    /// 正在处理（识别、整理、粘贴）的任务：等 AI 时按 Esc 或打开 tidytalk://cancel 可以取消，不再粘贴。
    private var processingTask: Task<Void, Never>?
    /// 粘贴字幕前等用户松开 ⌃⌥：每 50 毫秒看一次，最多 1 秒，否则模拟的 ⌘V 会带上这两个键。
    private static let modifierReleaseStep: Duration = .milliseconds(50)
    private static let modifierReleaseSteps = 20
    /// 从菜单里重新整理时，等菜单关闭、焦点回到原来的输入框。
    private static let menuCloseDelay: Duration = .milliseconds(150)

    init(model: AppModel, indicator: IndicatorPanel) {
        self.model = model
        self.indicator = indicator
        recognizers = RecognizerStore(model: model)

        hotkeys.onAction = { [weak self] action, purpose in self?.handle(action, purpose) }
        hotkeys.onEscapeWhileIdle = { [weak self] in self?.cancelProcessing() }
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
        recognizers.canReleaseCurrent = { [weak self] in
            guard let self else { return true }
            // 会议录音和会后处理也在用这个识别器
            return !recorder.isRecording && !isProcessing && !model.meetingActive
        }
        corrections.onCorrections = { [weak self] found in
            guard let self else { return }
            let fresh = model.suggestCorrections(found)
            // 正在说话或处理时不打扰
            guard let first = fresh.first, model.phase == .idle else { return }
            showMessage(String(localized: "发现改动：\(first.from) → \(first.to)，可在菜单里加入词库"))
        }
    }

    func start() {
        startHotkeysIfPossible()
        recognizers.load()
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

    /// 实时字幕、文件转写也用这个识别器，共用一份模型。
    func readyRecognizer() async -> (any SpeechTranscribing)? {
        await recognizers.ready()
    }

    // MARK: - 外部控制（tidytalk://）

    var isRecording: Bool { recorder.isRecording }

    /// 开始或结束说话输入；正在处理上一段话时忽略。
    func externalToggle() {
        guard !isProcessing else { return }
        hotkeys.externalToggle()
    }

    func externalStart() {
        if !recorder.isRecording { externalToggle() }
    }

    func externalStop() {
        if recorder.isRecording, purpose == .dictation { externalToggle() }
    }

    func externalCancel() {
        hotkeys.externalCancel()
        if !recorder.isRecording { cancelProcessing() }
    }

    /// 取消正在进行的处理：不再粘贴，收起指示器。
    func cancelProcessing() {
        guard isProcessing, let processingTask else { return }
        processingTask.cancel()
        self.processingTask = nil
        isProcessing = false
        hide()
    }

    /// 开始一次处理（识别后整理、粘贴字幕、重新整理），记下任务以便取消。
    private func startProcessing(_ work: @escaping @MainActor () async -> Void) {
        isProcessing = true
        processingTask = Task {
            await work()
            // 被取消后可能已经开始了新的处理，不要动新的状态
            guard !Task.isCancelled else { return }
            isProcessing = false
            processingTask = nil
        }
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

        // Apple 系统识别的模型由系统管理，可能在 Tidytalk 运行期间被删除或换了语言：每次使用时在后台重新检查
        if config.speechModel == .apple { model.models.refreshAppleStatus() }
        // 上一次粘贴后的"自动学词"比较到此为止，免得把这次的语音改写、快捷短语当成手动改词
        corrections.stop()
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
        startLive(model: config.speechModel, preview: config.livePreview)
    }

    /// 模型已经加载好时，录音期间每隔一小段时间把已经确定的片段先识别掉，并刷新胶囊下方的预览。
    private func startLive(model speechModel: SpeechModel, preview: Bool) {
        stopLive()
        // 模型还没加载好时不预览，松开后再整段识别
        guard let recognizer = recognizers.current else { return }
        let session = LiveTranscription(recognizer: recognizer, maxSeconds: speechModel.chunkSeconds)
        live = session
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveInterval)
                guard let self, !Task.isCancelled, recorder.isRecording else { return }
                session.commit { self.recorder.recordedSamples(from: $0) }
                guard preview, let raw = await session.preview(fetch: { self.recorder.recordedSamples(from: $0) }),
                      !Task.isCancelled, recorder.isRecording else { continue }
                let text = TextPipeline.prepare(raw, config: model.configStore.config)
                guard TranscriptCleanup.hasContent(text) else { continue }
                model.livePreview = text
                if !model.showsLivePreview { model.showsLivePreview = true }
            }
        }
    }

    /// 停止录音期间的识别，并取消还没开始的识别任务。
    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        live?.cancel()
        live = nil
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
        stopLive()
        recorder.cancel()
        hide()
    }

    private func finishRecording() {
        guard recorder.isRecording else { return }
        // 停止刷新预览，但保留已经显示的文字，处理期间继续可见；已经识别好的片段留给下面使用
        let session = live
        liveTask?.cancel()
        liveTask = nil
        live = nil
        let lostInput = recorder.lostInput()
        let samples = recorder.stop()
        if model.configStore.config.sounds { Sounds.finish() }
        let duration = Double(samples.count) / Double(AudioMath.sampleRate)
        guard duration >= Self.minimumDuration else {
            session?.cancel()
            hide()
            return
        }
        if lostInput, purpose == .rewrite {
            // 麦克风中途断开、一直没有恢复：改写要求只听到一半，不能照着改
            session?.cancel()
            showMessage(String(localized: "麦克风中途断开了，请再说一次"))
            return
        }

        model.phase = .processing
        let source = purpose
        startProcessing { [weak self] in
            await self?.process(samples, for: source, live: session, inputLost: lostInput)
        }
    }

    // MARK: - 处理

    /// - Parameter inputLost: 麦克风中途断开、一直没有恢复。照常粘贴已经录到的部分，最后提示后面的没录到。
    private func process(_ samples: [Float], for source: HotkeyMonitor.Purpose,
                         live: LiveTranscription? = nil, inputLost: Bool = false) async {
        guard let recognizer = await readyRecognizer() else {
            showMessage(String(localized: "语音识别模型加载失败"))
            return
        }

        let transcript: String
        if let live, live.uses(recognizer) {
            transcript = await live.finish(with: samples)
        } else {
            // 录音期间换了模型：旧模型上还没开始的片段不用再识别了
            live?.cancel()
            transcript = await recognizer.transcribe(samples)
        }
        guard !Task.isCancelled else { return }
        guard TranscriptCleanup.hasContent(transcript) else {
            // Apple 系统识别出错时（模型被删、不支持当前语言）说明原因，而不是"没有听到内容"
            if let reason = (recognizer as? AppleSpeechRecognizer)?.lastError {
                // 系统的识别模型可能被删了：重新检查，设置里的状态随之更新
                model.models.refreshAppleStatus()
                showMessage(reason)
            } else if inputLost {
                showMessage(String(localized: "麦克风中途断开了，请再说一次"))
            } else {
                showMessage(String(localized: "没有听到内容"))
            }
            return
        }

        // 每次整理前重新读取配置文件，手动修改后无需重启；刚启动时等钥匙串里的 API Key 读完
        await model.configStore.keychainReady()
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

        if inputLost {
            showMessage(String(localized: "麦克风中途断开了，后面的话没有录到"))
        } else if let notice = result.notice {
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
                                                             level: config.cleanupLevel, vocabulary: config.vocabulary) {
                        output = valid
                        outputLanguage = language
                    } else {
                        notice = failure
                    }
                } catch let error as AppleIntelligence.Failure {
                    notice = String(localized: "\(error.localizedDescription)，已粘贴原文")
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

    /// 从菜单粘贴最近记录前调用：上一次说话输入的"自动学词"比较到此为止，免得把这次粘贴当成手动改词。
    func stopCorrectionWatch() {
        corrections.stop()
    }

    // MARK: - 实时字幕

    /// 把实时字幕里听到的一段话按说话输入的规则（词库、整理模式、输出语言）整理后，粘贴到当前的输入框。
    func pasteCaptions(_ transcript: String) {
        guard !isProcessing, !recorder.isRecording else {
            // 正在说话输入或处理上一段话：提示一声，免得以为没反应
            NSSound.beep()
            return
        }
        model.configStore.reload()
        let config = model.configStore.config
        messageTask?.cancel()
        model.sparkles = false
        model.indicatorTag = indicatorTag(for: .dictation, config: config)
        model.phase = .processing
        indicator.show()
        startProcessing { [weak self] in
            guard let self else { return }
            for _ in 0..<Self.modifierReleaseSteps where !NSEvent.modifierFlags.intersection([.control, .option]).isEmpty {
                try? await Task.sleep(for: Self.modifierReleaseStep)
            }
            await model.configStore.keychainReady()
            let config = model.configStore.config
            let result = await cleanup(transcript, config: config, style: config.style,
                                       language: config.outputLanguage, enabled: config.cleanupEnabled)
            if await paste(result.text, transcript: transcript) {
                if let notice = result.notice { showMessage(notice) } else { hide() }
            }
        }
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
        messageTask?.cancel()
        model.sparkles = false
        model.indicatorTag = language.indicatorTag ?? String(localized: "整理")
        model.phase = .processing
        indicator.show()
        startProcessing { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.menuCloseDelay)
            let result = await cleanup(entry.transcript, config: config, style: style, language: language, enabled: true)
            guard !Task.isCancelled else { return }
            if result.succeeded {
                if await paste(result.text, transcript: entry.transcript) { hide() }
            } else {
                showMessage(String(localized: "重新整理失败，没有粘贴"))
            }
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
        // 处理期间被取消（Esc、tidytalk://cancel）：不再粘贴
        guard !Task.isCancelled else { return false }
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
        if kind == .dictation, model.configStore.config.learnCorrections {
            corrections.watch(pasted: text)
        } else {
            // 语音改写、快捷短语粘贴进同一个输入框，不要被当成用户手动改词
            corrections.stop()
        }
        return true
    }

    // MARK: - 指示器

    func showMessage(_ text: String) {
        // 被取消的处理任务（Esc、tidytalk://cancel）还会走到这里，例如网络请求被取消后报"改写失败"。
        // 这时指示器可能已经在显示新的录音，不能再动它
        guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        messageTask?.cancel()
        stopLivePreview()
        model.phase = .idle
        indicator.hide()
    }

    // MARK: - 实时预览

    /// 停止刷新预览并清掉显示的文字。
    private func stopLivePreview() {
        liveTask?.cancel()
        liveTask = nil
        model.livePreview = ""
        if model.showsLivePreview { model.showsLivePreview = false }
    }
}
