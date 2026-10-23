import Foundation
import TidytalkCore

/// 录音期间的实时预览：反复识别最新的一段音频。
///
/// 未定稿的部分超过一定长度时，在停顿处把前面的部分定稿，以后不再重复识别，
/// 所以说得再久，每次刷新的耗时也基本不变。只是预览，最终结果仍在松开后整段识别。
actor LivePreviewEngine {
    /// 未定稿的部分超过这个长度时，在停顿处把前面的部分定稿。
    static let windowSeconds: Double = 18

    private let recognizer: any SpeechTranscribing
    private var committedText = ""
    private var committedSamples = 0

    init(recognizer: any SpeechTranscribing) {
        self.recognizer = recognizer
    }

    /// 传入到目前为止录到的全部音频，返回预览文字；新增的音频太短时返回 nil。
    func update(with samples: [Float]) async -> String? {
        let rate = AudioMath.sampleRate
        guard samples.count - committedSamples > rate / 2 else { return nil }

        var window = Array(samples[committedSamples...])
        if Double(window.count) > Self.windowSeconds * Double(rate) {
            let ranges = AudioMath.chunkRanges(window, maxSeconds: Self.windowSeconds * 0.7)
            for range in ranges.dropLast() {
                let text = await recognizer.transcribe(Array(window[range]))
                committedText = Transcript.join([committedText, text])
            }
            let consumed = ranges.dropLast().last?.upperBound ?? 0
            committedSamples += consumed
            window = Array(window[consumed...])
        }
        let current = await recognizer.transcribe(window)
        return Transcript.join([committedText, current])
    }
}
