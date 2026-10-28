import AppKit
import Foundation
import Observation
import TidytalkCore

/// 会议模式：同时录自己的麦克风和电脑的声音，会议中边录边出粗稿（"我"和"对方"），
/// 结束后交给 `MeetingProcessor` 分说话人、精修文字、去掉回声。
@MainActor
@Observable
final class MeetingController {
    enum Phase: Equatable {
        case idle
        case recording
        /// 已经停止录音，正在识别还没识别完的几句
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// 正在录的会议（会议中的粗稿实时更新）。
    private(set) var current: Meeting?
    /// 两路的电平，录制界面显示。
    private(set) var levels: [MeetingSource: Float] = [:]
    /// 录音中出现的问题（麦克风断开、收不到电脑声音）。
    private(set) var warning: String?
    /// 说完了、还在排队识别的那几路（开会中的页面上显示“正在识别……”）
    private(set) var queued: Set<MeetingSource> = []

    /// 会议收听的来源：全部应用，或者设置里选的那个应用的名字。
    var listenSourceName: String {
        let id = model.configStore.config.meetingSource
        guard !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return String(localized: "全部应用")
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    /// 已经录了多久，每秒更新。
    private(set) var elapsed: TimeInterval = 0

    /// 开始和结束时通知外面（菜单栏图标、停掉实时字幕、注册快捷键）。
    @ObservationIgnored var onStart: (() -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    private let model: AppModel
    let store: MeetingStore
    let processor: MeetingProcessor
    private let recognizer: () async -> (any SpeechTranscribing)?

    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var transcribers: [MeetingSource: LiveMeetingTranscriber] = [:]
    /// 已经说完、等着识别的句子，按说完的先后排队。
    @ObservationIgnored private var pending: [LiveMeetingTranscriber.Sentence] = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var heardSystemSound = false

    /// 识别结果每隔这么久写一次盘，应用意外退出时最多丢这么多粗稿（录音本身不会丢）。
    private static let saveInterval: TimeInterval = 15
    /// 开始几秒后还一点电脑声音都没有、而别的应用又在发声：多半是没有"录制系统音频"的权限。
    private static let silenceCheckDelay: Duration = .seconds(6)

    init(model: AppModel, store: MeetingStore, processor: MeetingProcessor,
         recognizer: @escaping () async -> (any SpeechTranscribing)?) {
        self.model = model
        self.store = store
        self.processor = processor
        self.recognizer = recognizer
    }

    var isRecording: Bool { phase == .recording }

    func toggle() {
        phase == .idle ? start() : stop()
    }

    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 开发用：截图时显示录制界面（不真的录音）。
    func simulateRecording(_ meeting: Meeting, elapsed: TimeInterval, levels: [MeetingSource: Float]? = nil,
                           warning: String? = nil, queued: Set<MeetingSource> = []) {
        current = meeting
        phase = .recording
        self.elapsed = elapsed
        self.levels = levels ?? [.microphone: 0.55, .system: 0.3]
        self.warning = warning
        self.queued = queued
    }

    func simulateIdle() {
        current = nil
        phase = .idle
        levels = [:]
        warning = nil
        queued = []
    }
    #endif

    // MARK: - 开始

    func start() {
        guard phase == .idle else { return }
        model.refreshPermissions()
        guard model.microphoneGranted else {
            onError?(String(localized: "会议模式需要授权麦克风"))
            return
        }
        guard model.models.isReady else {
            onError?(model.readinessDescription)
            return
        }
        let config = model.configStore.config
        let meeting = Meeting(title: Meeting.defaultTitle(for: Date()), startedAt: Date())
        do {
            try store.create(meeting)
            let recorder = try MeetingRecorder(micURL: store.pcmURL(meeting.id, .microphone),
                                               systemURL: store.pcmURL(meeting.id, .system)) { [transcribers = makeTranscribers()] chunk in
                transcribers[chunk.source]?.accept(chunk)
            }
            recorder.onWarning = { [weak self] message in self?.warning = message }
            recorder.onLevel = { [weak self] source, level in
                guard let self else { return }
                levels[source] = level
                if source == .system, level > 0.02, !heardSystemSound {
                    heardSystemSound = true
                    model.noteSystemAudio(heard: true)
                }
            }
            try recorder.start(micDevice: config.microphone, appBundleID: config.meetingSource)
            self.recorder = recorder
        } catch {
            store.delete(meeting.id)
            transcribers = [:]
            onError?(String(localized: "无法开始会议：\(error.localizedDescription)"))
            return
        }
        current = meeting
        warning = nil
        elapsed = 0
        heardSystemSound = false
        pending = []
        queued = []
        phase = .recording
        model.meetingRecording = true
        startClock()
        checkSystemAudio(meeting.id)
        onStart?()
    }

    /// 两路各一个语音检测器；说完的句子回到主线程排队识别。
    private func makeTranscribers() -> [MeetingSource: LiveMeetingTranscriber] {
        var result: [MeetingSource: LiveMeetingTranscriber] = [:]
        for source in MeetingSource.allCases {
            guard let transcriber = try? LiveMeetingTranscriber(source: source, onSentence: { [weak self] sentence in
                Task { @MainActor in self?.enqueue(sentence) }
            }) else { continue }
            result[source] = transcriber
        }
        transcribers = result
        return result
    }

    private func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.elapsed
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// 没有"录制系统音频"权限时系统不报错，只是给静音。几秒后检查一次，提示去授权。
    private func checkSystemAudio(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.silenceCheckDelay)
            guard let self, current?.id == id, phase == .recording, !heardSystemSound,
                  AudioProcesses.somethingElseIsPlaying() else { return }
            warning = String(localized: "收不到电脑的声音：请在\"系统设置 › 隐私与安全性 › 录制系统音频\"里允许 Tidytalk")
            model.noteSystemAudio(heard: false)
            Permissions.openSystemAudioSettings()
        }
    }

    // MARK: - 会议中识别

    private func enqueue(_ sentence: LiveMeetingTranscriber.Sentence) {
        guard current != nil else { return }
        pending.append(sentence)
        pending.sort { $0.start < $1.start }
        queued = Set(pending.map(\.source))
        work()
    }

    /// 按说完的先后识别。说话输入正在录音或处理时先等它，不抢识别器。
    private func work() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            while true {
                if pending.isEmpty {
                    guard phase == .finishing else { return }
                    // 停止前送出的几句还在回主线程的路上：让它们先进队列
                    await Task.yield()
                    if pending.isEmpty {
                        finish()
                        return
                    }
                }
                if model.phase != .idle {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                guard let recognizer = await recognizer() else {
                    warning = String(localized: "语音识别模型加载失败")
                    pending.removeAll()
                    return
                }
                let sentence = pending.removeFirst()
                let raw = await recognizer.transcribe(sentence.samples)
                guard current != nil else { return }
                append(sentence, text: raw)
                queued = Set(pending.map(\.source))
            }
        }
    }

    private func append(_ sentence: LiveMeetingTranscriber.Sentence, text raw: String) {
        guard TranscriptCleanup.hasContent(raw), var meeting = current else { return }
        let config = model.configStore.config
        let text = TextPipeline.finish(TextPipeline.prepare(raw, config: config), config: config, style: .standard)
        guard TranscriptCleanup.hasContent(text) else { return }
        let rate = Double(AudioMath.sampleRate)
        let start = Double(sentence.start) / rate
        meeting.segments.append(MeetingSegment(
            id: meeting.segments.count, start: start, end: start + Double(sentence.samples.count) / rate,
            source: sentence.source, speakerIDs: [sentence.source == .microphone ? MeetingSpeaker.me.id : MeetingSpeaker.remoteAll.id],
            text: text))
        meeting.segments.sort { $0.start < $1.start }
        current = meeting
        if Date().timeIntervalSince(lastSave) > Self.saveInterval {
            lastSave = Date()
            try? store.save(meeting)
        }
    }

    // MARK: - 结束

    func stop() {
        guard phase == .recording, let recorder else { return }
        clock?.invalidate()
        clock = nil
        let duration = recorder.stop()
        self.recorder = nil
        current?.duration = duration
        current?.state = .processing
        // 还没说完的那句也当作说完
        for transcriber in transcribers.values { pending += transcriber.flush() }
        phase = .finishing
        model.meetingRecording = false
        model.meetingProcessing = true
        levels = [:]
        onStop?()
        if let current { try? store.save(current) }
        // 等排队的几句识别完再交给会后处理
        if !working { work() }
    }

    private func finish() {
        guard let meeting = current else { return }
        transcribers = [:]
        current = nil
        phase = .idle
        try? store.save(meeting)
        processor.process(meeting.id)
    }
}

/// 一路音频的语音检测：在自己的串行队列上把连续的音频切成一句句话，带上在音轨里的位置。
final class LiveMeetingTranscriber: @unchecked Sendable {
    struct Sentence: Sendable {
        let source: MeetingSource
        /// 在音轨里的起点（样本序号）
        let start: Int
        let samples: [Float]
    }

    private let source: MeetingSource
    private let detector: VoiceActivityDetector
    private let queue: DispatchQueue
    private let onSentence: @Sendable (Sentence) -> Void
    /// 送进检测器的第一个样本在音轨里的位置（总是 0：录音从头到尾每一块都会送进来）。
    private var origin: Int?

    init(source: MeetingSource, onSentence: @escaping @Sendable (Sentence) -> Void) throws {
        self.source = source
        // 和文件转写一样，一句最长 20 秒；停顿 0.6 秒算一句结束
        detector = try VoiceActivityDetector(minSilence: 0.6, maxSpeech: 20)
        queue = DispatchQueue(label: "app.tidytalk.meeting-vad.\(source.rawValue)", qos: .userInitiated)
        self.onSentence = onSentence
    }

    /// 在音频线程上调用，按到达顺序处理。
    func accept(_ chunk: MeetingRecorder.Chunk) {
        queue.async { [self] in
            if origin == nil { origin = chunk.start }
            for segment in detector.acceptSegments(chunk.samples) { emit(segment) }
        }
    }

    /// 把还没结束的那句也当作结束，直接返回（不再经过回调），停止时不会漏掉最后一句。
    func flush() -> [Sentence] {
        queue.sync {
            detector.flushSegments().map(sentence)
        }
    }

    private func emit(_ segment: VoiceActivityDetector.Segment) {
        onSentence(sentence(segment))
    }

    private func sentence(_ segment: VoiceActivityDetector.Segment) -> Sentence {
        Sentence(source: source, start: (origin ?? 0) + segment.start, samples: segment.samples)
    }
}
