import Testing
@testable import TidytalkCore

@Suite struct AudioMathTests {
    @Test func shortAudioIsSingleChunk() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 10)
        #expect(AudioMath.chunkRanges(samples) == [0..<samples.count])
    }

    @Test func longAudioSplitsAtQuietPoint() {
        let sr = 16_000
        var samples = [Float](repeating: 0.3, count: sr * 60)
        // 第 20 秒附近有一段静音
        for i in (sr * 20)..<(sr * 20 + sr / 5) { samples[i] = 0 }
        let ranges = AudioMath.chunkRanges(samples, maxSeconds: 25, searchSeconds: 8)
        #expect(ranges.first!.lowerBound == 0)
        #expect(ranges.last!.upperBound == samples.count)
        #expect(ranges.allSatisfy { $0.count <= sr * 25 })
        let firstCut = ranges[0].upperBound
        #expect(abs(firstCut - sr * 20) < sr / 5)
        // 区间首尾相接
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    }

    @Test func levelMapping() {
        #expect(AudioMath.level(fromRMS: 0) == 0)
        #expect(AudioMath.level(fromRMS: 1) == 1)
        #expect(AudioMath.level(fromRMS: 0.001) == 0)
    }
}
