import AppKit
import Observation
import TidytalkCore

/// 转写文件或链接：读取音频 → 按停顿切句 → 用当前的识别模型逐句识别。全部在这台 Mac 上完成。
/// 每次转写都保存成一条记录（`TranscriptionStore`）；链接下载的音频和封面图留在记录里，可以回放、另存。
@MainActor
@Observable
final class TranscribeController {
    enum Stage: Equatable {
        case idle
        case installingTool
        case downloading(Double)
        case decoding(Double)
        case splitting
        case recognizing(done: Int, total: Int)
        case finished
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed: false
            default: true
            }
        }

        /// 进度条的位置；nil 表示不确定进度。
        var fraction: Double? {
            switch self {
            case .downloading(let f), .decoding(let f): f
            case .recognizing(let done, let total): total > 0 ? Double(done) / Double(total) : nil
            default: nil
            }
        }

        var description: String {
            switch self {
            case .idle, .finished: ""
            case .installingTool: String(localized: "正在下载 yt-dlp…")
            case .downloading(let f): String(localized: "正在下载音频 \(Int(f * 100))%")
            case .decoding: String(localized: "正在读取音频…")
            case .splitting: String(localized: "正在分句…")
            case .recognizing(let done, let total): String(localized: "正在识别 \(String(done))/\(String(total))")
            case .failed(let message): message
            }
        }
    }

    /// 没能建成记录的失败（链接格式不对、下载失败、文件读不出来），显示在对应的标签页里。
    struct Failure: Equatable {
        let kind: Transcription.Kind
        let message: String
    }

    private(set) var stage: Stage = .idle
    /// 正在转写的记录
    private(set) var current: UUID?
    /// 最近一次转写的文字（转写中实时增加）
    private(set) var segments: [TranscriptSegment] = []
    /// 文件名或视频标题
    private(set) var title = ""
    private(set) var failure: Failure?

    let store: TranscriptionStore
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let recognizer: () async -> (any SpeechTranscribing)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel, store: TranscriptionStore,
         recognizer: @escaping () async -> (any SpeechTranscribing)?) {
        self.model = model
        self.store = store
        self.recognizer = recognizer
    }

    /// 当前使用的识别模型名称。
    var modelTitle: String { model.configStore.config.speechModel.title }

    var isBusy: Bool { stage.isBusy }

    @discardableResult
    func transcribe(file url: URL) -> UUID? {
        let item = Transcription(kind: .file, title: url.deletingPathExtension().lastPathComponent,
                                 model: modelTitle, sourcePath: url.path)
        return start(item) { _ in url }
    }

    /// 先用 yt-dlp 下载音频（第一次用时先下载 yt-dlp），再转写。下载的音频保存在记录里。
    @discardableResult
    func transcribe(link: String) -> UUID? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            failure = Failure(kind: .link, message: String(localized: "请输入以 http:// 或 https:// 开头的链接"))
            return nil
        }
        let item = Transcription(kind: .link, title: link, model: modelTitle, link: link)
        return start(item) { [weak self] directory in
            if !YTDLP.isInstalled {
                self?.stage = .installingTool
                try await YTDLP.install()
            } else if YTDLP.isOutdated {
                // 更新失败（例如没网）时继续用旧版本
                self?.stage = .installingTool
                try? await YTDLP.install()
            }
            self?.stage = .downloading(0)
            let result = try await YTDLP.downloadAudio(from: link, into: directory) { fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.stage else { return }
                    self.stage = .downloading(fraction)
                }
            }
            if let self, let id = self.current {
                self.title = result.title
                let size = (try? result.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                self.store.update(id) {
                    $0.title = result.title
                    $0.uploader = result.uploader
                    $0.audioFile = result.file.lastPathComponent
                    $0.audioSize = size
                    $0.thumbnailFile = result.thumbnail?.lastPathComponent
                }
            }
            return result.file
        }
    }

    func cancel() {
        task?.cancel()
    }

    func clearFailure() {
        failure = nil
    }

    private func start(_ item: Transcription, source: @escaping (URL) async throws -> URL) -> UUID? {
        guard !stage.isBusy else { return nil }
        failure = nil
        guard model.models.isReady else {
            failure = Failure(kind: item.kind, message: model.readinessDescription)
            return nil
        }
        do {
            try store.create(item)
        } catch {
            failure = Failure(kind: item.kind, message: error.localizedDescription)
            return nil
        }
        let id = item.id
        current = id
        segments = []
        title = item.title
        stage = .decoding(0)
        if item.kind == .link { stage = .downloading(0) }
        task = Task {
            let outcome = await run(id: id, source: source)
            finish(id, outcome)
        }
        return id
    }

    private enum Outcome {
        case finished, cancelled, failed(String)
    }

    private func run(id: UUID, source: @escaping (URL) async throws -> URL) async -> Outcome {
        do {
            let file = try await source(store.directory(for: id))
            stage = .decoding(0)
            let samples = try await AudioFileDecoder.load(file) { fraction in
                // 外层的任务本来就持有 self，转写结束前不会释放
                Task { @MainActor in
                    guard case .decoding = self.stage else { return }
                    self.stage = .decoding(fraction)
                }
            }
            store.update(id) { $0.duration = Double(samples.count) / Double(AudioMath.sampleRate) }
            stage = .splitting
            // 后台任务不会自动继承取消，要手动传进去，用户点"停止"时切句才能停下
            let splitting = Task.detached { try FileTranscriber.split(samples) }
            let pieces = try await withTaskCancellationHandler { try await splitting.value } onCancel: {
                splitting.cancel()
            }
            guard let recognizer = await recognizer() else { return .failed(String(localized: "语音识别模型加载失败")) }
            stage = .recognizing(done: 0, total: pieces.count)
            let config = model.configStore.config
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                let raw = await recognizer.transcribe(Array(samples[piece.range]))
                if TranscriptCleanup.hasContent(raw) {
                    let text = TextPipeline.finish(TextPipeline.prepare(raw, config: config), config: config,
                                                   style: .standard)
                    segments.append(TranscriptSegment(id: index, start: piece.start, end: piece.end, text: text))
                } else if index == 0, let reason = (recognizer as? AppleSpeechRecognizer)?.lastError {
                    // Apple 系统识别出错（模型被删、不支持当前语言）时直接说明原因
                    return .failed(reason)
                }
                stage = .recognizing(done: index + 1, total: pieces.count)
            }
            return segments.isEmpty ? .failed(String(localized: "没有听到内容")) : .finished
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 保存结果。一句都没有识别出来时不留记录（下载的音频一起删掉），错误显示在标签页里。
    private func finish(_ id: UUID, _ outcome: Outcome) {
        let kind = store.item(id)?.kind ?? .file
        let segments = segments
        switch outcome {
        case .finished:
            store.update(id) {
                $0.segments = segments
                $0.state = .finished
            }
            stage = .finished
        case .cancelled where segments.isEmpty:
            store.delete(id)
            stage = .idle
        case .cancelled:
            store.update(id) {
                $0.segments = segments
                $0.state = .finished
                $0.isPartial = true
            }
            stage = .finished
        case .failed(let message) where segments.isEmpty:
            store.delete(id)
            failure = Failure(kind: kind, message: message)
            stage = .failed(message)
        case .failed(let message):
            store.update(id) {
                $0.segments = segments
                $0.state = .failed
                $0.error = message
                $0.isPartial = true
            }
            stage = .failed(message)
        }
        current = nil
        task = nil
    }
}
