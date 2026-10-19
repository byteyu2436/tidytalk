import CSherpaOnnx
import Foundation
import TidytalkCore

/// Silero VAD（sherpa-onnx C API）：在连续的音频里找出一句句话。
///
/// 不是线程安全的，只在同一个串行队列上调用。
final class VoiceActivityDetector: @unchecked Sendable {
    enum LoadError: LocalizedError {
        case modelMissing
        case createFailed

        var errorDescription: String? { String(localized: "语音检测模型加载失败") }
    }

    /// 模型每次处理的样本数（16 kHz 下 32 ms）。
    static let windowSize = 512

    private let detector: OpaquePointer
    private var remainder: [Float] = []

    /// - Parameters:
    ///   - minSilence: 停顿多久算一句话结束。
    ///   - maxSpeech: 一句话最长多少秒，超过后在较弱的地方切开，字幕不会一直不出结果。
    init(minSilence: Float = 0.5, maxSpeech: Float = 10) throws {
        guard let url = Self.modelURL else { throw LoadError.modelMissing }
        let model = strdup(url.path)
        let provider = strdup("cpu")
        defer { [model, provider].forEach { free($0) } }

        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = UnsafePointer(model)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.window_size = Int32(Self.windowSize)
        config.silero_vad.max_speech_duration = maxSpeech
        config.sample_rate = Int32(AudioMath.sampleRate)
        config.num_threads = 1
        config.provider = UnsafePointer(provider)

        guard let d = SherpaOnnxCreateVoiceActivityDetector(&config, 30) else { throw LoadError.createFailed }
        detector = d
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    /// 随应用打包的模型；`swift run` 时从源码目录读取。
    private static var modelURL: URL? {
        if let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") { return url }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/silero_vad.onnx")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// 一句话：在整段音频里的起点（样本序号）和音频。
    struct Segment {
        let start: Int
        let samples: [Float]
    }

    /// 送入 16 kHz 单声道音频，返回这期间结束的句子。
    func accept(_ samples: [Float]) -> [[Float]] {
        acceptSegments(samples).map(\.samples)
    }

    /// 和 `accept` 一样，同时给出每句话的起点，用于文件转写的时间戳。
    func acceptSegments(_ samples: [Float]) -> [Segment] {
        remainder.append(contentsOf: samples)
        let usable = remainder.count / Self.windowSize * Self.windowSize
        if usable > 0 {
            remainder.withUnsafeBufferPointer { buf in
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buf.baseAddress, Int32(usable))
            }
            remainder.removeFirst(usable)
        }
        return popSegments()
    }

    /// 是否正在说话（一句话开始了还没结束）。
    var isSpeaking: Bool {
        SherpaOnnxVoiceActivityDetectorDetected(detector) != 0
    }

    /// 把还没结束的那句话也当作结束，返回剩下的句子。
    func flush() -> [[Float]] {
        flushSegments().map(\.samples)
    }

    func flushSegments() -> [Segment] {
        SherpaOnnxVoiceActivityDetectorFlush(detector)
        remainder.removeAll()
        return popSegments()
    }

    func reset() {
        SherpaOnnxVoiceActivityDetectorReset(detector)
        remainder.removeAll()
    }

    private func popSegments() -> [Segment] {
        var segments: [Segment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            if let segment = SherpaOnnxVoiceActivityDetectorFront(detector) {
                let n = Int(segment.pointee.n)
                if n > 0, let samples = segment.pointee.samples {
                    segments.append(Segment(start: Int(segment.pointee.start),
                                            samples: Array(UnsafeBufferPointer(start: samples, count: n))))
                }
                SherpaOnnxDestroySpeechSegment(segment)
            }
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return segments
    }
}
