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

    /// 语音检测切出的句子（起点和长度，单位是样本）往前补一点，免得吞掉开头的字（F4）：
    /// 检测器确认开始说话时，这句话已经开始了一小会儿。补的部分不超过上一句的结尾，
    /// 否则边界上的字会被识别两次，字幕时间也会互相重叠。
    public static func paddedRanges(_ segments: [(start: Int, count: Int)], padding: Int, total: Int) -> [Range<Int>] {
        var previousEnd = 0
        return segments.compactMap { segment in
            let end = min(total, segment.start + segment.count)
            let start = max(previousEnd, max(0, segment.start - padding))
            guard start < end else { return nil }
            previousEnd = end
            return start..<end
        }
    }

    /// 还在录音时，已经可以确定下来的片段：除最后一段（还在变长）以外的所有片段。
    ///
    /// 每个切点只取决于它前面不超过 `maxSeconds` 的音频，所以这些片段和录完后整段切分的结果完全一样，
    /// 可以先识别，松开后只需要识别最后一段。
    public static func finishedChunks(_ samples: [Float], sampleRate: Int = sampleRate, maxSeconds: Double) -> [Range<Int>] {
        Array(chunkRanges(samples, sampleRate: sampleRate, maxSeconds: maxSeconds).dropLast())
    }
}
