import AppKit
import TidytalkCore

/// 实时字幕：收听电脑的声音 → 切分句子 → 本地识别 → 显示在字幕条上。
///
/// 音频和识别结果都只在这台 Mac 上处理，不调用 AI。
@MainActor
final class ListenController {
    private let model: AppModel
    private let recognizer: () async -> (any SpeechTranscribing)?
    private var capture: SystemAudioCapture?
    private var segmenter: SpeechSegmenter?

    /// 等待识别的句子（按顺序）和最新一次的识别中预览。
    private var finals: [(samples: [Float], start: Date, end: Date)] = []
    private var pendingPartial: [Float]?
    private var generation = 0
    /// 第几轮收听。每次打开字幕加一，上一轮还在识别、翻译的结果回来时对不上就丢掉（E1）
    private var session = 0
    /// 正在跑识别循环的那一轮字幕。
    private var workingSession: Int?
    /// 预览识别比较慢时（Whisper、Fun-ASR），按耗时拉长两次预览的间隔，免得识别器一直被占满（E3）
    private var partialCooldownUntil = Date.distantPast
    /// 输出设备变化后的重新收听：合并短时间内的多次通知，失败时重试几次再放弃（E4）
    private var restartTask: Task<Void, Never>?
    private static let restartDelays: [Duration] = [.milliseconds(300), .milliseconds(700), .milliseconds(1500)]
    /// 打开字幕后这么久一直收到全是 0 的音频、同时又有应用在发声，多半是没有"录制系统音频"的权限（E2）
    private static let silenceCheckDelay: Duration = .seconds(5)
    private let heardSound = SoundFlag()
    /// 等待翻译的句子和正在翻译的数量。本机模型比较慢，同时最多翻译几句，来不及时跳过已经滚走的旧句子。
    private var translationQueue: [Int] = []
    private var translating = 0
    private static let maxTranslations = 2
    /// 每次收听只提示一次翻译失败，避免每句都弹出来。
    private var reportedTranslationError = false
    /// 边听边翻译：同时只翻译一次正在说的这句，记下上次送去翻译的文字和时间，控制调用次数。
    private var translatingPartial = false
    private var lastPartialSource = ""
    private var lastPartialRequest = Date.distantPast

    /// 字幕条按这些回调显示、隐藏。
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 开发用：记录切出的每一句和识别结果。
    var onDebug: ((String) -> Void)?

    init(model: AppModel, recognizer: @escaping () async -> (any SpeechTranscribing)?) {
        self.model = model
        self.recognizer = recognizer
        SystemAudioCapture.observeOutputDevice { [weak self] in
            // 换了输出设备（插上耳机等）后，在新设备上重新收听
            Task { @MainActor in self?.scheduleRestart() }
        }
    }

    func toggle() {
        model.isListening ? stop() : start()
    }

    func start() {
        guard !model.isListening else { return }
        guard model.models.isReady else {
            onError?(model.readinessDescription)
            return
        }
        session += 1
        let current = session
        let segmenter: SpeechSegmenter
        do {
            segmenter = try SpeechSegmenter { [weak self] event in
                Task { @MainActor in self?.handle(event, session: current) }
            }
        } catch {
            onError?(error.localizedDescription)
            return
        }
        self.segmenter = segmenter
        model.captions.clear()
        translationQueue.removeAll()
        reportedTranslationError = false
        model.isListening = true
        model.listeningPaused = false
        guard startCapture() else {
            stop()
            return
        }
        onStart?()
        // 提前加载识别模型，第一句话出来时不用等
        Task { _ = await recognizer() }
        checkForSilence(session: current)
    }

    /// 没有"录制系统音频"权限时系统不报错，只是给全是 0 的音频。收听期间每隔几秒检查一次，
    /// 直到听到过声音为止：有别的应用在发声、收到的却一直是静音时，提示去授权（每次收听只提示一次）。
    private func checkForSilence(session current: Int) {
        heardSound.reset()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.silenceCheckDelay)
                guard let self, current == self.session, model.isListening, !heardSound.value else { return }
                guard !model.listeningPaused, AudioProcesses.somethingElseIsPlaying() else { continue }
                onError?(String(localized: "收不到电脑的声音：请在\"系统设置 › 隐私与安全性 › 录制系统音频\"里允许 Tidytalk"))
                Permissions.openSystemAudioSettings()
                return
            }
        }
    }

    func stop() {
        guard model.isListening else { return }
        restartTask?.cancel()
        restartTask = nil
        capture?.stop()
        capture = nil
        segmenter = nil
        finals.removeAll()
        pendingPartial = nil
        translationQueue.removeAll()
        generation += 1
        model.isListening = false
        model.listeningPaused = false
        onStop?()
    }

    func setPaused(_ paused: Bool) {
        guard model.isListening, paused != model.listeningPaused else { return }
        model.listeningPaused = paused
        if paused {
            capture?.stop()
            capture = nil
            segmenter?.reset()
            pendingPartial = nil
            generation += 1
            model.captions.partial = ""
        } else if !startCapture() {
            stop()
        }
    }

    /// 来源改了以后马上切换。
    func restartIfRunning() {
        guard model.isListening, !model.listeningPaused else { return }
        restartTask?.cancel()
        restartTask = nil
        capture?.stop()
        capture = nil
        segmenter?.reset()
        if !startCapture() { stop() }
    }

    /// 输出设备变了、格式变了、要收听的应用多了新的发声进程：稍等一下再重新收听，失败时重试，
    /// 插拔 AirPods 时新设备可能还没准备好，一次失败就关掉字幕不合适。
    func scheduleRestart() {
        guard model.isListening, !model.listeningPaused else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            for (attempt, delay) in Self.restartDelays.enumerated() {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, model.isListening, !model.listeningPaused else { return }
                capture?.stop()
                capture = nil
                segmenter?.reset()
                if startCapture(reportErrors: attempt == Self.restartDelays.count - 1) {
                    restartTask = nil
                    return
                }
            }
            self?.restartTask = nil
            self?.stop()
        }
    }

    private func startCapture(reportErrors: Bool = true) -> Bool {
        guard let segmenter else { return false }
        let heard = heardSound
        let capture = SystemAudioCapture { samples in
            if !heard.value, samples.contains(where: { $0 != 0 }) { heard.set() }
            segmenter.accept(samples)
        }
        capture.onNeedsRestart = { [weak self] in
            Task { @MainActor in self?.scheduleRestart() }
        }
        do {
            try capture.start(appBundleID: model.configStore.config.listenSource)
        } catch {
            if reportErrors { onError?(error.localizedDescription) }
            return false
        }
        self.capture = capture
        return true
    }

    // MARK: - 识别

    private func handle(_ event: SpeechSegmenter.Event, session current: Int) {
        // 上一轮收听留下的句子（关掉后又马上打开）不要出现在新字幕里
        guard current == session, model.isListening, !model.listeningPaused else { return }
        switch event {
        case .partial(let samples):
            // 说话输入正在录音或处理时让出识别器；预览太慢时按耗时拉长间隔
            guard model.phase == .idle, Date() >= partialCooldownUntil else { return }
            pendingPartial = samples
        case .final(let samples):
            // 句子结束后检测器还要等一小段静音才确认，开头也多留了一点，按音频长度倒推时间
            let end = Date().addingTimeInterval(-0.5)
            let start = end.addingTimeInterval(-Double(samples.count) / Double(AudioMath.sampleRate) + 1)
            finals.append((samples, start, end))
            // 这句话已经说完，还在识别的预览作废
            pendingPartial = nil
            generation += 1
        }
        work()
    }

    /// 依次识别：说完的句子优先，有空时再更新正在说的这句。
    private func work() {
        // 按轮次记：快速关掉再打开字幕时，上一轮的循环可能还在等识别，不能挡住这一轮
        guard workingSession != session else { return }
        let current = session
        workingSession = current
        Task {
            defer { if workingSession == current { workingSession = nil } }
            guard let recognizer = await recognizer() else {
                onError?(String(localized: "语音识别模型加载失败"))
                stop()
                return
            }
            while model.isListening, current == session {
                if !finals.isEmpty {
                    let final = finals.removeFirst()
                    let text = await recognizer.transcribe(final.samples)
                    onDebug?("final \(final.samples.count) samples → \(text)")
                    guard model.isListening, current == session else { return }
                    lastPartialSource = ""
                    if let id = model.captions.commit(polish(text), start: min(final.start, final.end), end: final.end) {
                        requestTranslation(id)
                    }
                } else if let samples = pendingPartial {
                    pendingPartial = nil
                    let currentGeneration = generation
                    let started = Date()
                    let text = await recognizer.transcribe(samples)
                    // 识别比预览间隔还慢时，下一次预览往后推，留出识别器给说完的句子
                    partialCooldownUntil = Date().addingTimeInterval(max(0, Date().timeIntervalSince(started) * 1.5 - 0.6))
                    if currentGeneration == generation, current == session, model.isListening {
                        model.captions.partial = polish(text)
                        requestPartialTranslation()
                    }
                } else {
                    return
                }
            }
        }
    }

    // MARK: - 粘贴

    /// ⌃⌥V：把刚才那段话（从上一次较长的停顿开始，最多 30 秒）交给 `onPaste` 整理后粘贴。
    /// 只在收听时可用，不会在用户不知情时录音。
    func pasteRecent() {
        guard model.isListening else {
            onError?(String(localized: "先按 ⌃⌥C 打开实时字幕"))
            return
        }
        paste(model.captions.recentPassage())
    }

    /// 点字幕条上某一句旁边的"粘贴"：从那一句粘贴到最新。`id` 为 nil 表示正在说的这句。
    func paste(from id: Int?) {
        guard model.isListening else { return }
        paste(model.captions.passage(from: id))
    }

    var onPaste: ((String) -> Void)?

    private func paste(_ text: String) {
        guard TranscriptCleanup.hasContent(text) else {
            onError?(String(localized: "还没有可以粘贴的内容"))
            return
        }
        onPaste?(text)
    }

    // MARK: - 翻译

    /// 打开或关闭字幕翻译。打开时把屏幕上最后一句也翻译出来。
    func setTranslation(_ enabled: Bool) {
        if enabled, !model.configStore.config.ai.isConfigured {
            onError?(String(localized: "请先在设置里配置 AI"))
            return
        }
        model.configStore.update { $0.captionTranslate = enabled }
        if enabled, let last = model.captions.sentences.last, last.translation == nil {
            requestTranslation(last.id)
        }
    }

    private func requestTranslation(_ id: Int) {
        let config = model.configStore.config
        guard config.captionTranslate, config.ai.isConfigured,
              let sentence = model.captions.sentence(id),
              CaptionTranslation.needsTranslation(sentence.text, to: config.captionLanguage),
              model.captions.markTranslating(id)
        else { return }
        translationQueue.append(id)
        translateNext()
    }

    private func translateNext() {
        while translating < Self.maxTranslations, !translationQueue.isEmpty {
            // 积压太多时只翻译最近的几句，前面的已经滚出字幕条了
            if translationQueue.count > Self.maxTranslations * 2 {
                for id in translationQueue.dropLast(Self.maxTranslations) {
                    model.captions.setTranslation(model.captions.sentence(id)?.translation, for: id)
                }
                translationQueue.removeFirst(translationQueue.count - Self.maxTranslations)
            }
            let id = translationQueue.removeFirst()
            guard let sentence = model.captions.sentence(id) else { continue }
            // 正式译文回来之前，先显示边听边翻出来的译文（有的话）；失败时也保留它
            let provisional = sentence.translation
            let context = model.captions.sentences.prefix { $0.id != id }.suffix(2).map(\.text)
            let config = model.configStore.config
            let current = session
            translating += 1
            Task {
                defer {
                    translating -= 1
                    translateNext()
                }
                do {
                    let output = try await ChatCompletionClient(config: config.ai)
                        .translateCaption(sentence.text, context: context, language: config.captionLanguage,
                                          vocabulary: config.vocabulary)
                    guard model.isListening, current == session else { return }
                    let translation = CaptionTranslation.validate(original: sentence.text, translated: output)
                    model.captions.setTranslation(translation.map(polishTranslation) ?? provisional, for: id)
                } catch {
                    guard model.isListening, current == session else { return }
                    model.captions.setTranslation(provisional, for: id)
                    if !reportedTranslationError {
                        reportedTranslationError = true
                        onError?(String(localized: "字幕翻译失败：\(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// 边听边翻译正在说的这句。每次最多一个请求，至少隔 1.5 秒、多出几个字才再翻译；
    /// 这句说完后（generation 变了）回来的结果作废。失败时不提示，说完后整句翻译会再试。
    private func requestPartialTranslation() {
        let config = model.configStore.config
        let text = model.captions.partial
        guard config.captionTranslate, config.captionLiveTranslate, config.ai.isConfigured, !translatingPartial,
              PartialTranslationGate.shouldTranslate(text, lastSource: lastPartialSource,
                                                     sinceLastRequest: Date().timeIntervalSince(lastPartialRequest)),
              CaptionTranslation.needsTranslation(text, to: config.captionLanguage)
        else { return }
        translatingPartial = true
        lastPartialRequest = Date()
        lastPartialSource = text
        let session = generation
        let context = model.captions.sentences.suffix(2).map(\.text)
        Task {
            defer { translatingPartial = false }
            guard let output = try? await ChatCompletionClient(config: config.ai)
                .translateCaption(text, context: context, language: config.captionLanguage,
                                  vocabulary: config.vocabulary, partial: true),
                  model.isListening, session == generation, !model.captions.partial.isEmpty,
                  let translation = CaptionTranslation.validate(original: text, translated: output)
            else { return }
            model.captions.partialTranslation = polishTranslation(translation)
            onDebug?("partial translation: \(text) → \(translation)")
        }
    }

    /// 译文只套用中英文排版，不套用识别结果的替换表。
    private func polishTranslation(_ text: String) -> String {
        let config = model.configStore.config
        return TextPipeline.finish(text, config: config, style: .standard, language: config.captionLanguage)
    }

    /// 和说话输入一样套用替换表和中英文排版，但不调用 AI。
    private func polish(_ text: String) -> String {
        guard TranscriptCleanup.hasContent(text) else { return "" }
        let config = model.configStore.config
        return TextPipeline.finish(TextPipeline.prepare(text, config: config), config: config, style: .standard)
    }
}

/// 在后台队列上用语音检测把连续的音频切成一句句话。
///
/// 正在说的这句每隔一小段时间送出一次（用来实时预览），说完后送出完整的一句。
final class SpeechSegmenter: @unchecked Sendable {
    typealias Event = SentenceBuffer.Event

    private let queue = DispatchQueue(label: "app.tidytalk.listen", qos: .userInitiated)
    private let vad: VoiceActivityDetector
    private let onEvent: @Sendable (Event) -> Void
    /// 切句的规则在核心模块里，有单元测试；这里只负责把语音检测的结果交给它
    private var buffer = SentenceBuffer(maxSpeechSeconds: Int(VoiceActivityDetector.defaultMaxSpeech))

    init(onEvent: @escaping @Sendable (Event) -> Void) throws {
        vad = try VoiceActivityDetector()
        self.onEvent = onEvent
    }

    func accept(_ samples: [Float]) {
        queue.async { self.process(samples) }
    }

    func reset() {
        queue.async {
            self.vad.reset()
            self.buffer.reset()
        }
    }

    private func process(_ samples: [Float]) {
        let finished = vad.accept(samples)
        for event in buffer.process(samples, finished: finished, speaking: vad.isSpeaking) { onEvent(event) }
    }
}

/// 有没有收到过不是静音的音频：在收听队列上写，在主线程上读。
final class SoundFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false

    var value: Bool { lock.withLock { heard } }
    func set() { lock.withLock { heard = true } }
    func reset() { lock.withLock { heard = false } }
}
