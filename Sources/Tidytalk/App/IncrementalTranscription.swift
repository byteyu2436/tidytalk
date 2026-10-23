import Foundation
import TidytalkCore

/// 说长段话时边录边识别：录音每超过模型单段的长度，就在停顿处切下已经确定的片段先识别，
/// 松开后只需要识别最后一段，不用等整段录音从头识别。
///
/// 切点和录完后整段切分的结果完全一样（见 `AudioMath.finishedChunks`），所以识别结果不变，只是更快。
/// 短于单段长度的录音不会切分，和原来一样整段识别。
@MainActor
final class IncrementalTranscription {
    private let recognizer: any SpeechTranscribing
    private let maxSeconds: Double
    /// 已经交给识别器的音频长度（采样数）。
    private var committed = 0
    private var parts: [Task<String, Never>] = []

    init(recognizer: any SpeechTranscribing, maxSeconds: Double) {
        self.recognizer = recognizer
        self.maxSeconds = maxSeconds
    }

    /// 是否是用这个识别器开始的；录音期间换了模型时作废。
    func uses(_ other: any SpeechTranscribing) -> Bool { recognizer === other }

    /// 录音期间定期调用，传入到目前为止的全部音频。
    func update(with samples: [Float]) {
        guard samples.count > committed else { return }
        let pending = Array(samples[committed...])
        let ranges = AudioMath.finishedChunks(pending, maxSeconds: maxSeconds)
        guard let last = ranges.last else { return }
        for range in ranges {
            let chunk = Array(pending[range])
            let recognizer = recognizer
            parts.append(Task { await recognizer.transcribe(chunk) })
        }
        committed += last.upperBound
    }

    /// 录音结束：识别剩下的部分，按顺序拼接全部结果。
    func finish(with samples: [Float]) async -> String {
        if samples.count > committed {
            let tail = Array(samples[committed...])
            let recognizer = recognizer
            parts.append(Task { await recognizer.transcribe(tail) })
        }
        var texts: [String] = []
        for part in parts { texts.append(await part.value) }
        return Transcript.join(texts)
    }

    /// 至少切下了一段（录音超过了单段长度）。
    var hasCommittedChunks: Bool { committed > 0 }
}
