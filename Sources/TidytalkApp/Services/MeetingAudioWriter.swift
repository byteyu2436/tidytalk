@preconcurrency import AVFoundation
import Foundation
import TidytalkCore

/// 会议录音的一路音轨：录音时边录边写成没有文件头的 16-bit PCM（16 kHz 单声道），
/// 应用中途退出或崩溃时已经写进去的部分照样能读；会议结束后再转成体积小得多的 m4a。
///
/// 写文件在自己的串行队列上做，不占音频线程。
final class MeetingAudioWriter: @unchecked Sendable {
    let url: URL
    private let queue: DispatchQueue
    /// 只在 `queue` 上使用。
    private var handle: FileHandle?
    private let lock = NSLock()
    /// 已经交给写入队列的样本数（音轨的时间轴就是它）。只在持有 `lock` 时读写。
    private var queued = 0

    init(url: URL) throws {
        self.url = url
        queue = DispatchQueue(label: "app.tidytalk.meeting-writer.\(url.lastPathComponent)", qos: .utility)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// 已经写入（或正在写入）的样本数，可以在任何线程上调用。
    var sampleCount: Int { lock.withLock { queued } }

    /// 追加一段音频。可以在任何线程上调用，按调用顺序写入。
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock { queued += samples.count }
        queue.async { [self] in
            guard let handle else { return }
            try? handle.write(contentsOf: Self.int16Data(samples))
        }
    }

    /// 补一段静音（采集中断又恢复时，让两路音轨在时间上对齐）。
    func appendSilence(_ count: Int) {
        guard count > 0 else { return }
        append([Float](repeating: 0, count: count))
    }

    /// 写完剩下的数据并关闭文件。
    func finish() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    static func int16Data(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            }
        }
        return data
    }

    // MARK: - 读取和转换

    /// 读取整段 PCM 音轨，返回 16 kHz 单声道 Float32。
    static func readPCM(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(Int16(littleEndian: input[$0])) / Float(Int16.max) }
        }
    }

    /// 读取 PCM 音轨中从 `start` 到 `end`（秒）的一段，不把整段读进内存。
    static func readPCM(_ url: URL, from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let first = max(0, Int(start * Double(AudioMath.sampleRate)))
        let last = max(first, Int(end * Double(AudioMath.sampleRate)))
        try handle.seek(toOffset: UInt64(first * 2))
        let data = try handle.read(upToCount: (last - first) * 2) ?? Data()
        return data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            return (0..<(data.count / 2)).map { Float(Int16(littleEndian: input[$0])) / Float(Int16.max) }
        }
    }

    /// 把 PCM 音轨转成 AAC 的 m4a（约 32 kbps，一小时约 15 MB）。
    static func convertToM4A(_ pcm: URL, to output: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false)
        else { throw CocoaError(.fileWriteUnknown) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioMath.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let handle = try FileHandle(forReadingFrom: pcm)
        defer { try? handle.close() }
        let chunk = AudioMath.sampleRate * 10
        while let data = try handle.read(upToCount: chunk * 2), !data.isEmpty {
            let count = data.count / 2
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0]
            else { break }
            data.withUnsafeBytes { raw in
                let input = raw.bindMemory(to: Int16.self)
                for i in 0..<count { channel[i] = Float(Int16(littleEndian: input[i])) / Float(Int16.max) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
    }
}
