@preconcurrency import AVFoundation
import Foundation
import Speech
import TidytalkCore

/// macOS 自带的语音识别（SpeechAnalyzer）。识别模型由系统下载和管理，按系统语言识别。
enum AppleSpeech {
    enum SpeechError: LocalizedError {
        case unsupportedLanguage

        var errorDescription: String? { String(localized: "Apple 系统识别不支持当前的系统语言") }
    }

    /// 用哪一种识别模块、哪个语言。查询比较慢，同一个识别器里只查一次。
    enum ModuleChoice: Sendable {
        case transcriber(Locale)
        case dictation(Locale)

        func make() -> any SpeechModule {
            switch self {
            case .transcriber(let locale): SpeechTranscriber(locale: locale, preset: .transcription)
            case .dictation(let locale): DictationTranscriber(locale: locale, preset: .longDictation)
            }
        }
    }

    /// 按系统首选语言选择识别模块：优先用效果更好的 SpeechTranscriber，不支持时退回听写用的 DictationTranscriber。
    static func chooseModule() async -> ModuleChoice? {
        let preferred = Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return .transcriber(locale)
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
            return .dictation(locale)
        }
        return nil
    }

    static func makeModule() async -> (any SpeechModule)? {
        await chooseModule()?.make()
    }

    /// 系统的识别模型是否已经下载好。
    static func isInstalled() async -> Bool {
        guard let module = await makeModule() else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// 让系统下载识别模型，`onProgress` 回报 0...1 的进度。
    static func install(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let module = await makeModule() else { throw SpeechError.unsupportedLanguage }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let progress = request.progress
        let observation = progress.observe(\.fractionCompleted) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}

/// 用 Apple 系统识别转写一段录音。每次识别新建一个分析器，结束后释放。
final class AppleSpeechRecognizer: SpeechTranscribing, @unchecked Sendable {
    private let hotwords: [String]
    private let lock = NSLock()
    private var choice: AppleSpeech.ModuleChoice?
    private var error: String?

    init(hotwords: [String]) {
        self.hotwords = Array(hotwords.prefix(100))
    }

    /// 上一次识别失败的原因（没有安装模型、不支持当前语言等），成功时为 nil。
    var lastError: String? { lock.withLock { error } }

    func transcribe(_ samples: [Float]) async -> String {
        guard !samples.isEmpty else { return "" }
        do {
            let text = try await run(samples)
            lock.withLock { error = nil }
            return text
        } catch {
            lock.withLock { self.error = error.localizedDescription }
            return ""
        }
    }

    private func module() async -> (any SpeechModule)? {
        if let cached = lock.withLock({ choice }) { return cached.make() }
        guard let found = await AppleSpeech.chooseModule() else { return nil }
        lock.withLock { choice = found }
        return found.make()
    }

    private func run(_ samples: [Float]) async throws -> String {
        guard let module = await module() else { throw AppleSpeech.SpeechError.unsupportedLanguage }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !hotwords.isEmpty {
            // 词库里的词作为上下文提示，识别时优先认出它们
            let context = AnalysisContext()
            context.contextualStrings[.general] = hotwords
            try await analyzer.setContext(context)
        }

        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false),
              let input = Self.buffer(samples, format: source)
        else { return "" }
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? source
        let buffer = target == source ? input : Self.convert(input, to: target) ?? input

        // 先开始读取结果，再送入音频
        let collector = Task { () -> String in
            var parts: [String] = []
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
            }
            return Transcript.join(parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
