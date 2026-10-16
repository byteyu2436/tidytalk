import AppKit
import TidytalkCore

/// 实时字幕：收听电脑的声音 → 切分句子 → 本地识别 → 显示在字幕条上。
///
/// 音频和识别结果都只在这台 Mac 上处理，不调用 AI。
@MainActor
final class ListenController {
    private let model: AppModel
    private let recognizer: () async -> SpeechRecognizer?
    private var capture: SystemAudioCapture?
    private var segmenter: SpeechSegmenter?

    /// 等待识别的句子（按顺序）和最新一次的识别中预览。
    private var finals: [(samples: [Float], start: Date, end: Date)] = []
    private var pendingPartial: [Float]?
    private var generation = 0
    private var working = false
    /// 等待翻译的句子和正在翻译的数量。本机模型比较慢，同时最多翻译几句，来不及时跳过已经滚走的旧句子。
    private var translationQueue: [Int] = []
    private var translating = 0
    private static let maxTranslations = 2
    /// 每次收听只提示一次翻译失败，避免每句都弹出来。
    private var reportedTranslationError = false

    /// 字幕条按这些回调显示、隐藏。
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 开发用：记录切出的每一句和识别结果。
    var onDebug: ((String) -> Void)?

    init(model: AppModel, recognizer: @escaping () async -> SpeechRecognizer?) {
        self.model = model
        self.recognizer = recognizer
        SystemAudioCapture.observeOutputDevice { [weak self] in
            // 换了输出设备（插上耳机等）后，在新设备上重新收听
            Task { @MainActor in self?.restartIfRunning() }
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
        let segmenter: SpeechSegmenter
        do {
            segmenter = try SpeechSegmenter { [weak self] event in
                Task { @MainActor in self?.handle(event) }
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
    }

    func stop() {
        guard model.isListening else { return }
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
        capture?.stop()
        capture = nil
        segmenter?.reset()
        if !startCapture() { stop() }
    }

    private func startCapture() -> Bool {
        guard let segmenter else { return false }
        let capture = SystemAudioCapture { samples in segmenter.accept(samples) }
        do {
            try capture.start(appBundleID: model.configStore.config.listenSource)
        } catch {
            onError?(error.localizedDescription)
            return false
        }
        self.capture = capture
        return true
    }

    // MARK: - 识别

    private func handle(_ event: SpeechSegmenter.Event) {
        guard model.isListening, !model.listeningPaused else { return }
        switch event {
        case .partial(let samples):
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
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            guard let recognizer = await recognizer() else {
                onError?(String(localized: "语音识别模型加载失败"))
                stop()
                return
            }
            while model.isListening {
                if !finals.isEmpty {
                    let final = finals.removeFirst()
                    let text = await recognizer.transcribe(final.samples)
                    onDebug?("final \(final.samples.count) samples → \(text)")
                    guard model.isListening else { return }
                    if let id = model.captions.commit(polish(text), start: min(final.start, final.end), end: final.end) {
                        requestTranslation(id)
                    }
                } else if let samples = pendingPartial {
                    pendingPartial = nil
                    let current = generation
                    let text = await recognizer.transcribe(samples)
                    if current == generation, model.isListening { model.captions.partial = polish(text) }
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

    /// 点字幕条上的某一句：从那一句粘贴到最新。`id` 为 nil 表示点的是正在说的这句。
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
                for id in translationQueue.dropLast(Self.maxTranslations) { model.captions.setTranslation(nil, for: id) }
                translationQueue.removeFirst(translationQueue.count - Self.maxTranslations)
            }
            let id = translationQueue.removeFirst()
            guard let sentence = model.captions.sentence(id) else { continue }
            let context = model.captions.sentences.prefix { $0.id != id }.suffix(2).map(\.text)
            let config = model.configStore.config
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
                    guard model.isListening else { return }
                    let translation = CaptionTranslation.validate(original: sentence.text, translated: output)
                    model.captions.setTranslation(translation.map(polishTranslation), for: id)
                } catch {
                    guard model.isListening else { return }
                    model.captions.setTranslation(nil, for: id)
                    if !reportedTranslationError {
                        reportedTranslationError = true
                        onError?(String(localized: "字幕翻译失败：\(error.localizedDescription)"))
                    }
                }
            }
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
    enum Event: Sendable {
        case partial([Float])
        case final([Float])
    }

    private static let partialInterval = AudioMath.sampleRate * 6 / 10
    /// 开始说话之前保留的一小段，避免第一个字被切掉。
    private static let preroll = AudioMath.sampleRate / 2
    private static let maxRecent = AudioMath.sampleRate * 12

    private let queue = DispatchQueue(label: "app.tidytalk.listen", qos: .userInitiated)
    private let vad: VoiceActivityDetector
    private let onEvent: @Sendable (Event) -> Void
    private var recent: [Float] = []
    private var sincePartial = 0

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
            self.recent.removeAll()
            self.sincePartial = 0
        }
    }

    private func process(_ samples: [Float]) {
        recent.append(contentsOf: samples)
        for segment in vad.accept(samples) {
            // 自己保留的音频从开始说话前一点算起，比检测器切出的这段更完整，
            // 识别结果和刚才的预览一致，不会出现最后一下少了开头几个字
            onEvent(.final(recent.count >= segment.count ? recent : segment))
            recent.removeAll()
            sincePartial = 0
        }
        guard vad.isSpeaking else {
            if recent.count > Self.preroll { recent.removeFirst(recent.count - Self.preroll) }
            return
        }
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
        sincePartial += samples.count
        if sincePartial >= Self.partialInterval, recent.count >= Self.preroll * 2 {
            sincePartial = 0
            onEvent(.partial(recent))
        }
    }
}
