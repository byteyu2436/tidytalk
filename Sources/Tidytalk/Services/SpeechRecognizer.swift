import CSherpaOnnx
import Foundation
import TidytalkCore

/// SenseVoice-Small 本地识别（sherpa-onnx C API）。
///
/// 识别器加载后常驻内存，所有调用在内部串行队列上执行。
final class SpeechRecognizer: @unchecked Sendable {
    enum LoadError: LocalizedError {
        case createFailed

        var errorDescription: String? { String(localized: "语音识别模型加载失败") }
    }

    private let recognizer: OpaquePointer
    private let queue = DispatchQueue(label: "app.tidytalk.asr", qos: .userInitiated)

    /// 同步加载模型，耗时约 1 秒，不要在主线程调用。
    init(modelDirectory: URL) throws {
        let model = strdup(modelDirectory.appending(path: "model.int8.onnx").path)
        let tokens = strdup(modelDirectory.appending(path: "tokens.txt").path)
        let language = strdup("auto")
        let provider = strdup("cpu")
        let decoding = strdup("greedy_search")
        defer { [model, tokens, language, provider, decoding].forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(AudioMath.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = UnsafePointer(model)
        config.model_config.sense_voice.language = UnsafePointer(language)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = UnsafePointer(tokens)
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.model_config.provider = UnsafePointer(provider)
        config.decoding_method = UnsafePointer(decoding)

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else { throw LoadError.createFailed }
        recognizer = r
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// 识别 16 kHz 单声道音频。较长的录音会在停顿处分段识别后拼接。
    func transcribe(_ samples: [Float]) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let parts = AudioMath.chunkRanges(samples).map { range in
                    self.decode(samples[range])
                }
                continuation.resume(returning: Self.join(parts))
            }
        }
    }

    private func decode(_ samples: ArraySlice<Float>) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(AudioMath.sampleRate), buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 拼接分段结果：两侧都是拉丁字母或数字时补一个空格，中文直接相连。
    static func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.reduce(into: "") { result, part in
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               last.isASCII, first.isASCII,
               CharacterSet.alphanumerics.contains(first),
               CharacterSet.alphanumerics.contains(last) || CharacterSet.punctuationCharacters.contains(last) {
                result += " "
            }
            result += part
        }
    }
}
