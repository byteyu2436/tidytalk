import AppKit
import Observation
import TidytalkCore

/// 转写文件或链接：读取音频 → 按停顿切句 → 用当前的识别模型逐句识别。全部在这台 Mac 上完成。
@MainActor
@Observable
final class TranscribeController {
    enum Stage: Equatable {
        case idle
        case installingTool
        case downloading(Double)
        case decoding(Double)
        case recognizing(done: Int, total: Int)
        case finished
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed: false
            default: true
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var segments: [TranscriptSegment] = []
    /// 文件名或视频标题，导出时用作默认文件名。
    private(set) var title = ""

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let recognizer: () async -> (any SpeechTranscribing)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel, recognizer: @escaping () async -> (any SpeechTranscribing)?) {
        self.model = model
        self.recognizer = recognizer
    }

    func transcribe(file url: URL) {
        start(title: url.deletingPathExtension().lastPathComponent) { _ in url }
    }

    /// 先用 yt-dlp 下载音频（第一次用时先下载 yt-dlp），再转写，下载的音频转写后删除。
    func transcribe(link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            stage = .failed(String(localized: "请输入以 http:// 或 https:// 开头的链接"))
            return
        }
        start(title: link) { [weak self] directory in
            if !YTDLP.isInstalled {
                self?.stage = .installingTool
                try await YTDLP.install()
            }
            self?.stage = .downloading(0)
            let result = try await YTDLP.downloadAudio(from: link, into: directory) { fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.stage else { return }
                    self.stage = .downloading(fraction)
                }
            }
            self?.title = result.title
            return result.file
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 当前使用的识别模型名称。
    var modelTitle: String { model.configStore.config.speechModel.title }

    func clear() {
        guard !stage.isBusy else { return }
        segments = []
        title = ""
        stage = .idle
    }

    private func start(title: String, source: @escaping (URL) async throws -> URL) {
        guard !stage.isBusy else { return }
        guard model.models.isReady else {
            stage = .failed(model.readinessDescription)
            return
        }
        segments = []
        self.title = title
        task = Task {
            let directory = FileManager.default.temporaryDirectory.appending(path: "Tidytalk-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try await source(directory)
                stage = .decoding(0)
                let samples = try await AudioFileDecoder.load(file) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .decoding = self.stage else { return }
                        self.stage = .decoding(fraction)
                    }
                }
                let pieces = try await Task.detached { try FileTranscriber.split(samples) }.value
                guard let recognizer = await recognizer() else {
                    stage = .failed(String(localized: "语音识别模型加载失败"))
                    return
                }
                stage = .recognizing(done: 0, total: pieces.count)
                let config = model.configStore.config
                let rate = Double(AudioMath.sampleRate)
                for (index, piece) in pieces.enumerated() {
                    try Task.checkCancellation()
                    let raw = await recognizer.transcribe(piece.samples)
                    if TranscriptCleanup.hasContent(raw) {
                        let text = TextPipeline.finish(TextPipeline.prepare(raw, config: config), config: config,
                                                       style: .standard)
                        segments.append(TranscriptSegment(id: index, start: piece.start,
                                                          end: piece.start + Double(piece.samples.count) / rate,
                                                          text: text))
                    }
                    stage = .recognizing(done: index + 1, total: pieces.count)
                }
                stage = segments.isEmpty ? .failed(String(localized: "没有听到内容")) : .finished
            } catch is CancellationError {
                stage = segments.isEmpty ? .idle : .finished
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 导出

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptExport.render(segments, as: .text), forType: .string)
    }

    func export(as format: TranscriptExport.Format) {
        let panel = NSSavePanel()
        let name = title.isEmpty || title.hasPrefix("http") ? String(localized: "转写结果") : title
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? TranscriptExport.render(segments, as: format, title: name).write(to: url, atomically: true, encoding: .utf8)
    }
}
