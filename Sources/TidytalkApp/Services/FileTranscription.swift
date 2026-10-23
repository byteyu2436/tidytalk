@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import TidytalkCore

/// 读取音频或视频文件，转换为 16 kHz 单声道 Float32。
enum AudioFileDecoder {
    enum DecodeError: LocalizedError {
        case noAudio
        case unreadable
        case tooLong

        var errorDescription: String? {
            switch self {
            case .noAudio: String(localized: "这个文件里没有声音")
            case .unreadable: String(localized: "无法读取这个文件的音频，换成 MP3、M4A、WAV、MP4 或 MOV 试试")
            case .tooLong: String(localized: "文件太长了，一次最多转写 3 小时")
            }
        }
    }

    static let maxDuration: TimeInterval = 3 * 3600

    /// `onProgress` 回报 0...1 的读取进度。
    static func load(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DecodeError.noAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration <= maxDuration else { throw DecodeError.tooLong }

        // 后台任务不会自动继承取消，要手动传进去，用户点"停止"时才能停下
        let work = Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            // 由系统直接转换成识别需要的格式：16 kHz、单声道、32 位浮点
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioMath.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            guard reader.canAdd(output) else { throw DecodeError.unreadable }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? DecodeError.unreadable }

            var samples: [Float] = []
            let expected = max(1, Int(duration * Double(AudioMath.sampleRate)))
            samples.reserveCapacity(expected)
            var lastReport = 0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                chunk.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                samples.append(contentsOf: chunk)
                if samples.count - lastReport > AudioMath.sampleRate * 30 {
                    lastReport = samples.count
                    onProgress(min(1, Double(samples.count) / Double(expected)))
                }
            }
            guard reader.status == .completed else { throw reader.error ?? DecodeError.unreadable }
            guard !samples.isEmpty else { throw DecodeError.noAudio }
            return samples
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// 用语音检测把整段音频切成一句句话，再逐句识别，得到带时间戳的转写结果。
enum FileTranscriber {
    /// 切出的句子在整段音频里的位置。只记位置不复制音频，识别时再取出来：3 小时的文件约 690 MB，
    /// 每句都复制一份的话内存会翻几倍。
    struct Piece: Sendable {
        let range: Range<Int>
        var start: TimeInterval { Double(range.lowerBound) / Double(AudioMath.sampleRate) }
        var end: TimeInterval { Double(range.upperBound) / Double(AudioMath.sampleRate) }
    }

    /// 可以取消：长文件切句要几十秒，用户点"停止"时每 0.1 秒检查一次。
    static func split(_ samples: [Float]) throws -> [Piece] {
        // 文件转写不追求实时，句子可以长一点，断句更自然
        let vad = try VoiceActivityDetector(minSilence: 0.5, maxSpeech: 20)
        var spans: [VoiceActivityDetector.Span] = []
        // 和实时收听一样小块送入（0.1 秒）；一次送入很长的音频时，检测器只会切出最后一段
        let step = AudioMath.sampleRate / 10
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, offset + step)
            spans += vad.acceptSpans(samples[offset..<end])
            offset = end
        }
        spans += vad.flushSpans()
        // 往前多取 0.3 秒，免得吞掉开头的字（录音一开头就有人说话时最明显），但不和上一句重叠
        return AudioMath.paddedRanges(spans.map { ($0.start, $0.count) }, padding: AudioMath.sampleRate * 3 / 10,
                                      total: samples.count).map(Piece.init)
    }
}

/// 转写链接用的下载工具 yt-dlp：第一次用时从官方 GitHub 下载并校验，之后保存在应用支持目录里。
enum YTDLP {
    enum Failure: LocalizedError {
        case checksumMismatch
        case downloadFailed(String)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: String(localized: "下载的 yt-dlp 校验失败，请重试")
            case .downloadFailed(let message): message.isEmpty ? String(localized: "无法下载这个链接") : message
            case .unsupportedFormat: String(localized: "这个链接的音频格式暂不支持")
            }
        }
    }

    private static let release = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    private static let assetName = "yt-dlp_macos"

    static var executable: URL {
        URL.applicationSupportDirectory.appending(path: "Tidytalk/Tools/\(assetName)")
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// 视频网站经常改版，旧版本的 yt-dlp 过几周就可能下载不了：超过 14 天就重新下载最新版。
    static var isOutdated: Bool {
        guard let modified = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return true }
        return Date().timeIntervalSince(modified) > 14 * 24 * 3600
    }

    /// 下载官方发布的 macOS 版本，并用同一个发布里的 SHA2-256SUMS 校验。
    static func install() async throws {
        let (sums, _) = try await URLSession.shared.data(from: release.appending(path: "SHA2-256SUMS"))
        guard let line = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .first(where: { $0.hasSuffix(" " + assetName) }),
              let expected = line.split(separator: " ").first.map(String.init)
        else { throw Failure.checksumMismatch }

        let (temporary, response) = try await URLSession.shared.download(from: release.appending(path: assetName))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.downloadFailed("") }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw Failure.checksumMismatch }

        let directory = executable.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: temporary, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date()],
                                              ofItemAtPath: executable.path)
    }

    /// 只下载链接里的音频，返回文件位置和标题。`onProgress` 回报 0...1 的下载进度。
    static func downloadAudio(from link: String, into directory: URL,
                              onProgress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, title: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--no-playlist", "--newline", "--progress", "--no-warnings",
            // 优先下载系统能直接解码的 M4A 音频
            "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/bestaudio/best",
            "-o", directory.appending(path: "audio.%(ext)s").path,
            "--print", "after_move:title", "--print", "after_move:filepath",
            "--", link,
        ]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = LineCollector()
        let errors = LineCollector()
        let handleLine: @Sendable (String, LineCollector) -> Void = { line, collector in
            if let percent = Self.progress(in: line) {
                onProgress(percent / 100)
            } else {
                collector.append(line)
            }
        }
        // 一次读到的数据不一定正好是整行，按换行符拼好再处理
        let outBuffer = LineBuffer { handleLine($0, output) }
        let errBuffer = LineBuffer { handleLine($0, errors) }
        // 每个输出各用一个线程读到文件结尾（进程退出后才会读到结尾），读完再判断结果，最后两行（标题、文件路径）不会漏掉
        let readers = DispatchGroup()
        func read(_ pipe: Pipe, into buffer: LineBuffer) {
            let handle = pipe.fileHandleForReading
            DispatchQueue.global().async(group: readers) {
                // 直接用 POSIX read：有多少读多少，进度能及时更新；出错时返回 -1。
                // availableData 出错时抛的是 Objective-C 异常，Swift 接不住，应用会直接闪退；
                // read(upToCount:) 又要等读满或读到结尾才返回，下载进度会卡住
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = chunk.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        buffer.append(Data(chunk[..<count]))
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                buffer.finish()
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                    read(stdout, into: outBuffer)
                    read(stderr, into: errBuffer)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        await withCheckedContinuation { continuation in readers.notify(queue: .global()) { continuation.resume() } }
        try Task.checkCancellation()

        let lines = output.lines.filter { !$0.isEmpty }
        guard process.terminationStatus == 0, lines.count >= 2, let path = lines.last,
              FileManager.default.fileExists(atPath: path)
        else {
            // yt-dlp 的错误信息形如 "ERROR: [youtube] xxx: Video unavailable"
            let message = errors.lines.last(where: { $0.hasPrefix("ERROR") })?
                .replacingOccurrences(of: "ERROR: ", with: "") ?? ""
            throw Failure.downloadFailed(message)
        }
        return (URL(fileURLWithPath: path), lines[lines.count - 2])
    }

    /// 进度行形如 "[download]  42.3% of 3.21MiB at 1.2MiB/s ETA 00:02"。
    private static func progress(in line: String) -> Double? {
        guard line.hasPrefix("[download]"), let percent = line.split(separator: " ").first(where: { $0.hasSuffix("%") })
        else { return nil }
        return Double(percent.dropLast())
    }

    /// 把分批读到的输出拼成完整的行。
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            let lines: [String] = lock.withLock {
                pending.append(data)
                var result: [String] = []
                while let newline = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    result.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                return result
            }
            for line in lines where !line.isEmpty { onLine(line) }
        }

        /// 最后一行没有换行符时也处理掉。
        func finish() {
            let rest = lock.withLock { () -> String in
                defer { pending.removeAll() }
                return String(decoding: pending, as: UTF8.self)
            }
            if !rest.isEmpty { onLine(rest) }
        }
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
