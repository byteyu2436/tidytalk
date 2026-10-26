import Foundation
import Observation
import TidytalkCore

/// 会后处理：分说话人、按说话人重新识别、去掉回声、把录音转成 m4a；以及生成 AI 总结。
///
/// 处理期间会议详情页照常显示会议中识别的粗稿，处理完再换成分好说话人的版本。
@MainActor
@Observable
final class MeetingProcessor {
    /// 正在处理的会议和进度（0...1），界面上显示。
    struct Progress: Equatable {
        var stage: String
        var fraction: Double?
    }

    private(set) var progress: [UUID: Progress] = [:]
    /// 正在生成总结的会议。
    private(set) var summarizing: Set<UUID> = []
    /// 总结失败的原因，显示在总结页。
    private(set) var summaryErrors: [UUID: String] = [:]

    private let model: AppModel
    private let store: MeetingStore
    private let recognizer: () async -> (any SpeechTranscribing)?
    @ObservationIgnored private var diarizer: SpeakerDiarizer?
    @ObservationIgnored private var queue: [(id: UUID, speakers: Int?)] = []
    @ObservationIgnored private var running = false

    /// 一路音频里说话总时长不到这么多秒的"人"不算（咳嗽、背景里的一句话）。
    private static let minimumSpeakerSeconds: TimeInterval = 3

    init(model: AppModel, store: MeetingStore, recognizer: @escaping () async -> (any SpeechTranscribing)?) {
        self.model = model
        self.store = store
        self.recognizer = recognizer
    }

    func isProcessing(_ id: UUID) -> Bool { progress[id] != nil }

    /// 说话人模型（界面上显示下载状态）。
    var diarizationModels: ModelManager { model.diarizationModels }
    var diarizationReady: Bool { model.diarizationModels.isReady }
    /// 现在配置的 AI 服务（总结用）。
    var aiConfig: AIConfig { model.configStore.config.ai }

    /// 排队处理一场会议。`speakers` 是用户指定的对方人数（重新分说话人时），nil 表示自动判断。
    func process(_ id: UUID, remoteSpeakers speakers: Int? = nil) {
        guard progress[id] == nil else { return }
        progress[id] = Progress(stage: String(localized: "等待处理"))
        queue.append((id, speakers))
        model.meetingProcessing = true
        run()
    }

    /// 上次退出时还没录完或没处理完的会议（应用崩溃、强制退出）：录音文件还在，接着处理。
    func resumeInterrupted() {
        for meeting in store.meetings where meeting.state == .recording || meeting.state == .processing {
            if meeting.state == .recording {
                // 按录音文件的长度推算时长
                let bytes = (try? FileManager.default.attributesOfItem(atPath: store.pcmURL(meeting.id, .system).path)[.size]
                    as? Int) ?? 0
                store.update(meeting.id) {
                    $0.duration = Double(bytes / 2) / Double(AudioMath.sampleRate)
                    $0.state = .processing
                }
            }
            process(meeting.id)
        }
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            defer {
                running = false
                model.meetingProcessing = !queue.isEmpty || !progress.isEmpty
            }
            while !queue.isEmpty {
                let job = queue.removeFirst()
                await processNow(job.id, remoteSpeakers: job.speakers)
                progress[job.id] = nil
            }
        }
    }

    // MARK: - 处理

    private func processNow(_ id: UUID, remoteSpeakers: Int?) async {
        guard var meeting = store.meeting(id) else { return }
        meeting.state = .processing
        try? store.save(meeting)
        do {
            let audio = try await loadAudio(meeting)
            let maxSeconds = model.configStore.config.speechModel.chunkSeconds
            var speakers: [MeetingSpeaker] = []
            var segments: [MeetingSegment] = []
            for source in MeetingSource.allCases {
                let samples = audio[source] ?? []
                let live = meeting.segments.filter { $0.source == source }
                guard !samples.isEmpty else {
                    // 这一路没有录音（录音已删除、或者根本没录到）：已经分好的说话人和文字原样保留
                    speakers += meeting.speakers.filter { $0.source == source }
                    segments += live
                    continue
                }
                let (trackSpeakers, trackSegments) = try await segmentsFor(
                    source, samples: samples, live: live, speakers: source == .system ? remoteSpeakers : nil,
                    maxSeconds: maxSeconds, id: id)
                speakers += trackSpeakers
                segments += trackSegments
            }
            segments = MeetingAlignment.removingEcho(from: segments).sorted { $0.start < $1.start }
            for index in segments.indices { segments[index].id = index }
            // 去掉回声后没说过话的人不列出来（扬声器漏进麦克风的声音会被分成"现场 1、2"）；"我"总是保留
            let used = Set(segments.flatMap(\.speakerIDs))
            speakers = speakers.filter { used.contains($0.id) || $0.id == MeetingSpeaker.me.id }

            // 用户之前改过的名字：同一个 id 的说话人保留名字（例如重新分说话人后"我"还是原来的名字）
            let names = Dictionary(meeting.speakers.compactMap { s in s.customName.map { (s.id, $0) } },
                                   uniquingKeysWith: { a, _ in a })
            meeting.speakers = speakers.map { speaker in
                var speaker = speaker
                speaker.customName = names[speaker.id]
                return speaker
            }
            meeting.segments = segments
            meeting.duration = max(meeting.duration,
                                   Double(audio.values.map(\.count).max() ?? 0) / Double(AudioMath.sampleRate))
            progress[id] = Progress(stage: String(localized: "正在保存录音"))
            meeting.hasRecording = await finishRecording(id)
            meeting.state = .ready
            meeting.processingError = nil
            try store.save(meeting)
            if model.configStore.config.meetingAutoSummary, meeting.summary == nil, model.configStore.config.ai.isConfigured {
                summarize(id)
            }
        } catch {
            meeting.state = .failed
            meeting.processingError = error.localizedDescription
            try? store.save(meeting)
        }
    }

    /// 两路音频：录音时的 PCM，已经转换过的就读 m4a。
    private func loadAudio(_ meeting: Meeting) async throws -> [MeetingSource: [Float]] {
        progress[meeting.id] = Progress(stage: String(localized: "正在读取录音"))
        var result: [MeetingSource: [Float]] = [:]
        for source in MeetingSource.allCases {
            let pcm = store.pcmURL(meeting.id, source)
            let m4a = store.audioURL(meeting.id, source)
            if FileManager.default.fileExists(atPath: pcm.path) {
                result[source] = try await Task.detached { try MeetingAudioWriter.readPCM(pcm) }.value
            } else if FileManager.default.fileExists(atPath: m4a.path) {
                result[source] = try await AudioFileDecoder.load(m4a) { _ in }
            }
        }
        return result
    }

    /// 一路音频分成几个人、每段话是谁说的。
    ///
    /// - 分出两个以上的人：按说话人的变化重新切分、重新识别（会议中按停顿切的一句可能横跨两个人）。
    /// - 只有一个人：直接用会议中识别的粗稿，不再识别一遍。
    /// - 没有下载说话人模型：同上，麦克风一路都是"我"，电脑声音一路都是"对方"。
    private func segmentsFor(_ source: MeetingSource, samples: [Float], live: [MeetingSegment], speakers: Int?,
                             maxSeconds: Double, id: UUID) async throws -> ([MeetingSpeaker], [MeetingSegment]) {
        let fallback = source == .microphone ? MeetingSpeaker.me : MeetingSpeaker.remoteAll
        guard let diarizer = loadDiarizer() else {
            return ([fallback], live.map { relabel($0, to: fallback.id) })
        }
        progress[id] = Progress(stage: source == .microphone ? String(localized: "正在分辨你这边的说话人")
                                    : String(localized: "正在分辨对方的说话人"), fraction: 0)
        let turns = await diarizer.diarize(samples, speakers: speakers) { [weak self] fraction in
            Task { @MainActor in self?.progress[id]?.fraction = fraction }
        }
        // 说得太少的"人"多半是噪音，并到别人里（不单独列出来）
        var totals: [Int: TimeInterval] = [:]
        for turn in turns { totals[turn.speaker, default: 0] += turn.end - turn.start }
        let real = Set(totals.filter { $0.value >= Self.minimumSpeakerSeconds }.keys)
        let kept = turns.filter { real.contains($0.speaker) }

        guard real.count > 1 || (speakers ?? 0) > 1 else {
            // 只有一个人：麦克风一路是"我"，电脑声音一路是"对方"
            if live.isEmpty, !kept.isEmpty {
                return ([fallback], try await transcribe(units: MeetingAlignment.units(from: kept, maxSeconds: maxSeconds),
                                                          samples: samples, source: source, ids: [:],
                                                          fallback: fallback.id, id: id))
            }
            return ([fallback], live.map { relabel($0, to: fallback.id) })
        }

        let (ids, trackSpeakers) = source == .microphone ? MeetingAlignment.microphoneSpeakers(kept)
            : MeetingAlignment.remoteSpeakers(kept)
        var units = MeetingAlignment.units(from: kept, maxSeconds: maxSeconds)
        // 分离没认出来的话（几个人叠在一起说、声音很小）用语音检测再找一遍，补上，不丢内容
        progress[id] = Progress(stage: String(localized: "正在检查有没有漏掉的话"))
        let sentences = try await Task.detached { try FileTranscriber.split(samples) }.value
        units = MeetingAlignment.filling(units, with: sentences.map { (start: $0.start, end: $0.end) })
        let segments = try await transcribe(units: units, samples: samples, source: source, ids: ids,
                                            fallback: fallback.id, id: id)
        return (trackSpeakers, segments)
    }

    private func transcribe(units: [MeetingAlignment.Unit], samples: [Float], source: MeetingSource,
                            ids: [Int: String], fallback: String, id: UUID) async throws -> [MeetingSegment] {
        let rate = Double(AudioMath.sampleRate)
        let config = model.configStore.config
        // 一口气说得太久的段在最安静的地方切开，每段不超过模型能处理的长度
        let maxSeconds = model.configStore.config.speechModel.chunkSeconds
        let units = units.flatMap { unit -> [MeetingAlignment.Unit] in
            guard unit.end - unit.start > maxSeconds else { return [unit] }
            let start = max(0, Int(unit.start * rate))
            let end = min(samples.count, Int(unit.end * rate))
            guard end > start else { return [] }
            return AudioMath.chunkRanges(Array(samples[start..<end]), maxSeconds: maxSeconds).map { range in
                MeetingAlignment.Unit(start: Double(start + range.lowerBound) / rate,
                                      end: Double(start + range.upperBound) / rate, speakers: unit.speakers)
            }
        }
        var segments: [MeetingSegment] = []
        for (index, unit) in units.enumerated() {
            try Task.checkCancellation()
            progress[id] = Progress(stage: String(localized: "正在识别（\(String(index + 1))/\(units.count)）"),
                                    fraction: Double(index) / Double(max(1, units.count)))
            // 说话输入正在用识别器：先等它
            while model.phase != .idle { try await Task.sleep(for: .milliseconds(300)) }
            guard let recognizer = await recognizer() else { throw ProcessingError.recognizerUnavailable }
            let start = max(0, Int(unit.start * rate))
            let end = min(samples.count, Int(unit.end * rate))
            guard end > start else { continue }
            let raw = await recognizer.transcribe(Array(samples[start..<end]))
            #if DEBUG || TIDYTALK_DEV_TOOLS
            // 开发用：TIDYTALK_MEETING_DEBUG=1 时打印每一段的识别结果（配合 --meeting-test）
            if ProcessInfo.processInfo.environment["TIDYTALK_MEETING_DEBUG"] != nil {
                print(String(format: "DEBUG %@ %.2f–%.2f %@ → %@", source.rawValue, unit.start, unit.end,
                             "\(unit.speakers)", raw))
            }
            #endif
            guard TranscriptCleanup.hasContent(raw) else { continue }
            let text = TextPipeline.finish(TextPipeline.prepare(raw, config: config), config: config, style: .standard)
            guard TranscriptCleanup.hasContent(text) else { continue }
            segments.append(MeetingSegment(id: segments.count, start: unit.start, end: unit.end, source: source,
                                           speakerIDs: unit.speakers.isEmpty ? [fallback] : unit.speakers.map { ids[$0] ?? fallback },
                                           text: text))
        }
        return segments
    }

    private func relabel(_ segment: MeetingSegment, to speaker: String) -> MeetingSegment {
        var segment = segment
        segment.speakerIDs = [speaker]
        return segment
    }

    private func loadDiarizer() -> SpeakerDiarizer? {
        if let diarizer { return diarizer }
        guard model.diarizationModels.isReady else { return nil }
        diarizer = try? SpeakerDiarizer(directory: model.diarizationModels.directory)
        return diarizer
    }

    /// 录音转成 m4a（设置里关掉"保留录音"时删掉）。返回录音是否还在。
    private func finishRecording(_ id: UUID) async -> Bool {
        let keep = model.configStore.config.meetingKeepRecording
        var kept = false
        for source in MeetingSource.allCases {
            let pcm = store.pcmURL(id, source)
            let m4a = store.audioURL(id, source)
            guard FileManager.default.fileExists(atPath: pcm.path) else {
                kept = kept || FileManager.default.fileExists(atPath: m4a.path)
                continue
            }
            if keep, (try? await Task.detached { try MeetingAudioWriter.convertToM4A(pcm, to: m4a) }.value) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: m4a.path)
                kept = true
            } else if keep {
                // 转换失败就留着 PCM，下次处理时再试
                kept = true
                continue
            }
            try? FileManager.default.removeItem(at: pcm)
        }
        return kept
    }

    enum ProcessingError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? { String(localized: "语音识别模型加载失败") }
    }

    // MARK: - AI 总结

    func summarize(_ id: UUID) {
        guard !summarizing.contains(id), let meeting = store.meeting(id) else { return }
        let config = model.configStore.config.ai
        summarizing.insert(id)
        summaryErrors[id] = nil
        Task {
            defer { summarizing.remove(id) }
            do {
                let (markdown, partial) = try await ChatCompletionClient(config: config).summarizeMeeting(meeting)
                store.update(id) {
                    $0.summary = MeetingSummary(markdown: markdown, createdAt: Date(), service: Self.serviceName(config),
                                                isPartial: partial)
                }
            } catch {
                summaryErrors[id] = error.localizedDescription
            }
        }
    }

    /// 总结下面显示用了哪个服务，例如"api.deepseek.com · deepseek-chat"、"Apple 智能"。
    static func serviceName(_ config: AIConfig) -> String {
        if config.service == .apple { return String(localized: "Apple 智能") }
        let host = URL(string: config.baseURL)?.host() ?? config.baseURL
        return "\(host) · \(config.model)"
    }

    /// 文字会发到哪里，"生成总结"按钮旁边说明。
    static func destination(_ config: AIConfig) -> String {
        if config.service == .apple { return String(localized: "用 Apple 智能在这台 Mac 上总结，文字不会离开这台 Mac") }
        if config.isLocal { return String(localized: "用本机的大模型总结，文字不会离开这台 Mac") }
        return String(localized: "会议文字会发送给 \(serviceName(config)) 来总结")
    }
}
