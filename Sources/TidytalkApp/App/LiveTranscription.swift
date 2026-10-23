import Foundation
import TidytalkCore

/// 录音期间的识别：边录边把已经说完的部分识别掉，同时给出实时预览。
///
/// - 录音每超过模型单段的长度，就在停顿处切下已经确定的片段先识别（见 `AudioMath.finishedChunks`），
///   松开后只需要识别最后一段。切点和录完后整段切分的结果完全一样，所以识别结果不变，只是更快。
/// - 实时预览直接用这些已经识别好的片段，只重新识别后面还没切下的部分，同一段音频不会识别两次。
/// - 短于单段长度的录音不会切分，和原来一样松开后整段识别。
@MainActor
final class LiveTranscription {
    private let recognizer: any SpeechTranscribing
    private let maxSeconds: Double

    private struct Part {
        let range: Range<Int>
        let task: Task<String, Never>
        var text: String?
    }

    private var parts: [Part] = []
    /// 已经交给识别器的音频长度（采样数）。
    private var committed = 0

    init(recognizer: any SpeechTranscribing, maxSeconds: Double) {
        self.recognizer = recognizer
        self.maxSeconds = maxSeconds
    }

    /// 是否是用这个识别器开始的；录音期间换了模型时作废。
    func uses(_ other: any SpeechTranscribing) -> Bool { recognizer === other }

    /// 录音期间定期调用。`fetch(offset)` 返回从第 offset 个样本到目前为止录到的音频。
    func commit(fetch: (Int) -> [Float]) {
        let pending = fetch(committed)
        let ranges = AudioMath.finishedChunks(pending, maxSeconds: maxSeconds)
        guard let last = ranges.last else { return }
        for range in ranges {
            let chunk = Array(pending[range])
            let recognizer = recognizer
            let task = Task { await recognizer.transcribe(chunk) }
            let index = parts.count
            parts.append(Part(range: (committed + range.lowerBound)..<(committed + range.upperBound), task: task))
            Task { [weak self] in
                let text = await task.value
                self?.parts[index].text = text
            }
        }
        committed += last.upperBound
    }

    /// 预览：已经识别好的片段，加上后面还没切下的部分的最新识别结果。新增的音频太短时返回 nil。
    ///
    /// 只重新识别还没交给识别器的部分（最长约一段的长度）：已经切下、还在识别的片段不再识别第二遍，
    /// 预览里先用"…"占位。这样一次预览的耗时有上限，松开时最终识别不会被一次很长的预览拖住。
    func preview(fetch: (Int) -> [Float]) async -> String? {
        let tail = fetch(committed)
        guard tail.count > AudioMath.sampleRate / 2 else { return nil }
        var texts: [String] = []
        for part in parts {
            guard let text = part.text else {
                texts.append("…")
                break
            }
            texts.append(text)
        }
        let current = await recognizer.transcribe(tail)
        guard !Task.isCancelled else { return nil }
        return Transcript.join(texts + [current])
    }

    /// 录音结束：识别剩下的部分，按顺序拼接全部结果。
    func finish(with samples: [Float]) async -> String {
        if samples.count > committed {
            let tail = Array(samples[committed...])
            let recognizer = recognizer
            parts.append(Part(range: committed..<samples.count, task: Task { await recognizer.transcribe(tail) }))
            committed = samples.count
        }
        // 处理被取消（Esc）时，排着队的片段也不用再识别了
        let tasks = parts.map(\.task)
        return await withTaskCancellationHandler {
            var texts: [String] = []
            for task in tasks { texts.append(await task.value) }
            return Transcript.join(texts)
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    /// 取消还没开始识别的片段（取消录音、录音中换了模型时），不再占着识别队列。
    func cancel() {
        for part in parts { part.task.cancel() }
    }
}
