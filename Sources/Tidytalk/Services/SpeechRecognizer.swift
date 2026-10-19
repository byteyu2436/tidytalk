import CSherpaOnnx
import Foundation
import TidytalkCore

/// 把 16 kHz 单声道音频识别成文字。各种模型（sherpa-onnx 的离线模型、Apple 系统识别）都实现这个接口。
protocol SpeechTranscribing: AnyObject, Sendable {
    func transcribe(_ samples: [Float]) async -> String
}

enum SpeechRecognizers {
    enum LoadError: LocalizedError {
        case createFailed

        var errorDescription: String? { String(localized: "语音识别模型加载失败") }
    }

    /// 加载选中的模型，耗时几秒，不要在主线程调用。
    /// - Parameter hotwords: 词库里的词，支持热词的模型识别时会优先认出它们。
    static func load(_ model: SpeechModel, directory: URL?, hotwords: [String]) throws -> any SpeechTranscribing {
        if model == .apple { return AppleSpeechRecognizer(hotwords: hotwords) }
        guard let directory else { throw LoadError.createFailed }
        return try SpeechRecognizer(model: model, directory: directory, hotwords: hotwords)
    }
}

/// sherpa-onnx 离线识别：SenseVoice、Qwen3-ASR、Fun-ASR-Nano、Whisper。
///
/// 识别器加载后常驻内存，所有调用在内部串行队列上执行。
final class SpeechRecognizer: SpeechTranscribing, @unchecked Sendable {
    private let recognizer: OpaquePointer
    private let model: SpeechModel
    private let queue = DispatchQueue(label: "app.tidytalk.asr", qos: .userInitiated)

    /// 同步加载模型，耗时约 1～5 秒，不要在主线程调用。
    init(model: SpeechModel, directory: URL, hotwords: [String] = []) throws {
        self.model = model
        // C 接口只在创建时读取这些字符串，创建完就可以释放
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        func path(_ name: String) -> UnsafePointer<CChar> { c(directory.appending(path: name).path) }
        // 热词用英文逗号分隔，词本身不能带逗号。热词会占用模型的上下文长度，最多取前 30 个
        let hotwordList = hotwords.map { $0.replacingOccurrences(of: ",", with: " ") }
            .filter { !$0.isEmpty }.prefix(30).joined(separator: ",")

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(AudioMath.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        #if DEBUG || TIDYTALK_DEV_TOOLS
        // 开发用：设置环境变量 TIDYTALK_ASR_DEBUG=1 时打印 sherpa-onnx 的调试信息
        if ProcessInfo.processInfo.environment["TIDYTALK_ASR_DEBUG"] != nil { config.model_config.debug = 1 }
        #endif

        switch model {
        case .senseVoice:
            config.model_config.sense_voice.model = path("model.int8.onnx")
            config.model_config.sense_voice.language = c("auto")
            config.model_config.sense_voice.use_itn = 1
            config.model_config.tokens = path("tokens.txt")
        case .qwen3ASR:
            config.model_config.qwen3_asr.conv_frontend = path("conv_frontend.onnx")
            config.model_config.qwen3_asr.encoder = path("encoder.int8.onnx")
            config.model_config.qwen3_asr.decoder = path("decoder.int8.onnx")
            config.model_config.qwen3_asr.tokenizer = path("tokenizer")
            config.model_config.qwen3_asr.max_total_len = 512
            // 每段最长 20 秒，说得快的中文大约 120 个字，留足余量
            config.model_config.qwen3_asr.max_new_tokens = 200
            config.model_config.qwen3_asr.temperature = 1e-6
            config.model_config.qwen3_asr.top_p = 0.8
            config.model_config.qwen3_asr.seed = 42
            config.model_config.qwen3_asr.hotwords = c(hotwordList)
        case .funASRNano:
            config.model_config.funasr_nano.encoder_adaptor = path("encoder_adaptor.int8.onnx")
            config.model_config.funasr_nano.embedding = path("embedding.int8.onnx")
            config.model_config.funasr_nano.llm = path("llm.int8.onnx")
            config.model_config.funasr_nano.tokenizer = path("Qwen3-0.6B")
            config.model_config.funasr_nano.itn = 1
            config.model_config.funasr_nano.hotwords = c(hotwordList)
        case .whisperTurbo:
            config.model_config.whisper.encoder = path("turbo-encoder.int8.onnx")
            config.model_config.whisper.decoder = path("turbo-decoder.int8.onnx")
            // 不指定语言，由模型自动判断
            config.model_config.whisper.language = c("")
            config.model_config.whisper.task = c("transcribe")
            config.model_config.whisper.tail_paddings = -1
            config.model_config.tokens = path("turbo-tokens.txt")
        case .apple:
            throw SpeechRecognizers.LoadError.createFailed
        }

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else { throw SpeechRecognizers.LoadError.createFailed }
        recognizer = r
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// 识别 16 kHz 单声道音频。较长的录音会在停顿处分段识别后拼接。
    func transcribe(_ samples: [Float]) async -> String {
        let maxSeconds = model.chunkSeconds
        return await withCheckedContinuation { continuation in
            queue.async {
                let parts = AudioMath.chunkRanges(samples, maxSeconds: maxSeconds).map { range in
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

    static func join(_ parts: [String]) -> String {
        Transcript.join(parts)
    }
}
