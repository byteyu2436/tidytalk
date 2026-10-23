import Foundation
import Testing
@testable import TidytalkApp
import TidytalkCore

/// 假的识别器：返回音频的样本数，记下每次识别了多长；`delay` 模拟慢模型，被取消时直接返回空文字。
final class FakeRecognizer: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var lengths: [Int] = []
    private var cancellations = 0
    let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var calls: [Int] { lock.withLock { lengths } }
    var cancelled: Int { lock.withLock { cancellations } }

    func transcribe(_ samples: [Float]) async -> String {
        lock.withLock { lengths.append(samples.count) }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch {
                lock.withLock { cancellations += 1 }
                return ""
            }
        }
        return "\(samples.count)"
    }
}

@MainActor
@Suite struct LiveTranscriptionTests {
    static let rate = AudioMath.sampleRate
    static let maxSeconds = 2.0
    static let tick = rate / 2

    /// 按 0.5 秒一次模拟录音期间的提交和预览，返回每次预览的文字。
    private func simulate(_ live: LiveTranscription, samples: [Float]) async -> [String] {
        var recorded = 0
        let fetch: (Int) -> [Float] = { offset in offset < recorded ? Array(samples[offset..<recorded]) : [] }
        var previews: [String] = []
        while recorded < samples.count {
            recorded = min(samples.count, recorded + Self.tick)
            live.commit(fetch: fetch)
            if let text = await live.preview(fetch: fetch) { previews.append(text) }
        }
        return previews
    }

    @Test func h3EveryPartIsRecognizedOnceAndJoinedInOrder() async {
        let samples = [Float](repeating: 0.1, count: Self.rate * 7)
        let fake = FakeRecognizer()
        let live = LiveTranscription(recognizer: fake, maxSeconds: Self.maxSeconds)
        _ = await simulate(live, samples: samples)
        let text = await live.finish(with: samples)
        // 最终结果的各段加起来正好是整段录音，没有重复也没有遗漏
        let counts = text.split(separator: " ").compactMap { Int($0) }
        #expect(counts.reduce(0, +) == samples.count)
        #expect(counts == AudioMath.chunkRanges(samples, maxSeconds: Self.maxSeconds).map(\.count))
    }

    @Test func h3PreviewNeverRecognizesCommittedAudioAgain() async {
        let samples = [Float](repeating: 0.1, count: Self.rate * 9)
        // 慢模型：切下的片段还没识别完，预览就来了
        let fake = FakeRecognizer(delay: .milliseconds(30))
        let live = LiveTranscription(recognizer: fake, maxSeconds: Self.maxSeconds)
        let previews = await simulate(live, samples: samples)
        _ = await live.finish(with: samples)
        // 每次识别都不超过一段的长度再加一次提交的间隔：预览只识别还没切下的部分
        let limit = Int(Self.maxSeconds * Double(Self.rate)) + Self.tick
        #expect(fake.calls.allSatisfy { $0 <= limit })
        #expect(!previews.isEmpty)
    }

    @Test func c7CancellingFinishCancelsQueuedParts() async {
        let samples = [Float](repeating: 0.1, count: Self.rate * 7)
        let fake = FakeRecognizer(delay: .seconds(5))
        let live = LiveTranscription(recognizer: fake, maxSeconds: Self.maxSeconds)
        live.commit { Array(samples[$0...]) }
        let start = Date()
        let task = Task { await live.finish(with: samples) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.value
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(fake.cancelled > 0)
    }
}
