import Foundation

/// 语音识别模型的文件清单和下载源。
public struct ModelSpec: Sendable {
    public struct File: Sendable {
        public let name: String
        public let size: Int64
        public let sha256: String
    }

    public struct Source: Sendable {
        public let name: String
        public let baseURL: URL

        public func url(for file: File) -> URL {
            baseURL.appending(path: file.name)
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
}
