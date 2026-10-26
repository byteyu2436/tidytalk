import Foundation

/// 模型（语音识别、说话人分离）的文件清单和下载源。
public struct ModelSpec: Sendable {
    public struct File: Sendable {
        /// 保存在本地目录里的文件名
        public let name: String
        public let size: Int64
        public let sha256: String
        /// 文件不在下载源的同一个仓库里时，相对于下载源网站根目录的路径（例如 "user/repo/resolve/main/model.onnx"）
        public let remotePath: String?

        public init(name: String, size: Int64, sha256: String, remotePath: String? = nil) {
            self.name = name
            self.size = size
            self.sha256 = sha256
            self.remotePath = remotePath
        }
    }

    public struct Source: Sendable {
        public let name: String
        public let baseURL: URL

        public func url(for file: File) -> URL {
            if let remotePath = file.remotePath, let root = URL(string: "/", relativeTo: baseURL) {
                return root.appending(path: remotePath).absoluteURL
            }
            return baseURL.appending(path: file.name)
        }
    }

    /// 本地目录名，版本变化时换一个目录。
    public let directoryName: String
    public let files: [File]
    /// 按顺序尝试，前一个失败自动换下一个。
    public let sources: [Source]

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static let senseVoice = ModelSpec(
        directoryName: "sense-voice-zh-en-2024-07-17",
        files: [
            File(name: "tokens.txt",
                 size: 315_894,
                 sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
            File(name: "model.int8.onnx",
                 size: 239_233_841,
                 sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
        ],
        sources: [
            Source(name: "Hugging Face",
                   baseURL: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main")!),
            Source(name: "HF-Mirror",
                   baseURL: URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main")!),
        ]
    )

    private static func huggingFace(_ repo: String) -> [Source] {
        [
            Source(name: "Hugging Face", baseURL: URL(string: "https://huggingface.co/\(repo)/resolve/main")!),
            Source(name: "HF-Mirror", baseURL: URL(string: "https://hf-mirror.com/\(repo)/resolve/main")!),
        ]
    }

    public static let qwen3ASR = ModelSpec(
        directoryName: "qwen3-asr-0.6b-int8-2026-03-25",
        files: [
            File(name: "conv_frontend.onnx", size: 44_148_281,
                 sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e"),
            File(name: "encoder.int8.onnx", size: 182_491_662,
                 sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9"),
            File(name: "decoder.int8.onnx", size: 755_914_231,
                 sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771"),
            File(name: "tokenizer/vocab.json", size: 2_776_833,
                 sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            File(name: "tokenizer/merges.txt", size: 1_671_853,
                 sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            File(name: "tokenizer/tokenizer_config.json", size: 12_487,
                 sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        ],
        sources: huggingFace("csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25")
    )

    public static let funASRNano = ModelSpec(
        directoryName: "funasr-nano-int8-2025-12-30",
        files: [
            File(name: "encoder_adaptor.int8.onnx", size: 237_792_748,
                 sha256: "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422"),
            File(name: "embedding.int8.onnx", size: 155_584_380,
                 sha256: "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644"),
            File(name: "llm.int8.onnx", size: 600_356_593,
                 sha256: "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a"),
            File(name: "Qwen3-0.6B/tokenizer.json", size: 11_422_654,
                 sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            File(name: "Qwen3-0.6B/vocab.json", size: 2_776_833,
                 sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            File(name: "Qwen3-0.6B/merges.txt", size: 1_671_853,
                 sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        ],
        sources: huggingFace("csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30")
    )

    public static let whisperTurbo = ModelSpec(
        directoryName: "whisper-turbo-int8",
        files: [
            File(name: "turbo-tokens.txt", size: 816_730,
                 sha256: "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"),
            File(name: "turbo-encoder.int8.onnx", size: 674_716_297,
                 sha256: "b02dcdf54f348741e93fe732b67d933c8dcb6735655f710640143081db38878b"),
            File(name: "turbo-decoder.int8.onnx", size: 361_080_764,
                 sha256: "20accd02388482eb3a46bd615631adfdc85e1eb2c7db9ea3f02a40ffe6b81547"),
        ],
        sources: huggingFace("csukuangfj/sherpa-onnx-whisper-turbo")
    )

    /// 会议模式的说话人分离：pyannote 分段模型（MIT）+ 3D-Speaker CAM++ 中英文声纹模型（Apache-2.0）。
    /// 两个文件在 Hugging Face 的不同仓库里，按各自的 remotePath 下载。
    public static let speakerDiarization = ModelSpec(
        directoryName: "speaker-diarization-pyannote3-campplus-zh-en",
        files: [
            File(name: "segmentation.int8.onnx", size: 1_540_506,
                 sha256: "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d",
                 remotePath: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.int8.onnx"),
            File(name: "embedding.onnx", size: 28_281_164,
                 sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
                 remotePath: "csukuangfj/speaker-embedding-models/resolve/main/"
                    + "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"),
        ],
        sources: [
            Source(name: "Hugging Face", baseURL: URL(string: "https://huggingface.co")!),
            Source(name: "HF-Mirror", baseURL: URL(string: "https://hf-mirror.com")!),
        ]
    )
}

/// 可以选择的语音识别模型。默认 SenseVoice：体积小、速度快，中英文混说效果好。
public enum SpeechModel: String, CaseIterable, Sendable {
    case senseVoice = "sense_voice"
    case qwen3ASR = "qwen3_asr"
    case funASRNano = "fun_asr_nano"
    case whisperTurbo = "whisper_turbo"
    /// macOS 自带的识别（SpeechAnalyzer），模型由系统管理。
    case apple

    public var title: String {
        switch self {
        case .senseVoice: "SenseVoice"
        case .qwen3ASR: "Qwen3-ASR"
        case .funASRNano: "Fun-ASR-Nano"
        case .whisperTurbo: "Whisper Turbo"
        case .apple: String(localized: "Apple 系统识别")
        }
    }

    public var summary: String {
        switch self {
        case .senseVoice: String(localized: "速度快，中文、英文、日文、韩文、粤语，中英文混说效果好。")
        case .qwen3ASR: String(localized: "最准确，支持 30 种语言和 22 种中文方言，能认出词库里的人名和术语。速度较慢，20 秒的话约需 4 秒。")
        case .funASRNano: String(localized: "中文、英文、日文，准确度接近 Qwen3-ASR，速度稍快。词库对它帮助不大。")
        case .whisperTurbo: String(localized: "支持约 99 种语言，适合小语种。中文会漏字，中文请用其他模型。")
        case .apple: String(localized: "macOS 自带，不占下载空间。按系统语言识别，中英文混说效果一般。")
        }
    }

    /// 需要下载的文件；Apple 系统识别由系统下载，为 nil。
    public var spec: ModelSpec? {
        switch self {
        case .senseVoice: .senseVoice
        case .qwen3ASR: .qwen3ASR
        case .funASRNano: .funASRNano
        case .whisperTurbo: .whisperTurbo
        case .apple: nil
        }
    }

    /// 能否把词库里的词作为热词，识别时优先认出它们。
    public var supportsHotwords: Bool {
        self == .qwen3ASR || self == .funASRNano || self == .apple
    }

    /// 每段送去识别的最长秒数：长录音在停顿处切开后分段识别。
    public var chunkSeconds: Double {
        switch self {
        case .senseVoice: 25
        case .qwen3ASR: 20
        case .funASRNano: 18
        case .whisperTurbo: 28
        case .apple: 55
        }
    }
}
