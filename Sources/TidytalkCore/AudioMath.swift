import Foundation

public enum AudioMath {
    public static let sampleRate = 16_000

    /// 均方根音量。
    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// 把 RMS 映射到 0...1 的电平，用于指示器显示（-50 dBFS 以下为 0）。
    public static func level(fromRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }

    /// 把长音频切成不超过 `maxSeconds` 的片段，尽量在最安静的地方切开。
    ///
    /// SenseVoice 对 30 秒以内的音频效果最好，2 分钟的录音需要分段识别。
    public static func chunkRanges(
        _ samples: [Float],
        sampleRate: Int = sampleRate,
        maxSeconds: Double = 25,
        searchSeconds: Double = 8
    ) -> [Range<Int>] {
        let maxLen = Int(maxSeconds * Double(sampleRate))
        let searchLen = Int(searchSeconds * Double(sampleRate))
        let frame = sampleRate / 50 // 20 ms
        let sampleCount = samples.count
        guard sampleCount > maxLen, frame > 0 else { return [0..<sampleCount] }

        var ranges: [Range<Int>] = []
        var start = 0
        while sampleCount - start > maxLen {
            let searchEnd = start + maxLen
            let searchStart = max(start + frame, searchEnd - searchLen)
            var bestCut = searchEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var pos = searchStart
            while pos + frame <= searchEnd {
                let e = rms(samples[pos..<pos + frame])
                if e < bestEnergy {
                    bestEnergy = e
                    bestCut = pos + frame / 2
                }
                pos += frame
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        ranges.append(start..<sampleCount)
        return ranges
    }
}
