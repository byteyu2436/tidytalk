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

        return try await Task.detached(priority: .userInitiated) {
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
        }.value
    }
}

/// 用语音检测把整段音频切成一句句话，再逐句识别，得到带时间戳的转写结果。
enum FileTranscriber {
    /// 切出的句子：起点（秒）和音频。
    struct Piece: Sendable {
        let start: TimeInterval
        let samples: [Float]
    }

    static func split(_ samples: [Float]) throws -> [Piece] {
        // 文件转写不追求实时，句子可以长一点，断句更自然
        let vad = try VoiceActivityDetector(minSilence: 0.5, maxSpeech: 20)
        var segments: [VoiceActivityDetector.Segment] = []
        // 和实时收听一样小块送入（0.1 秒）；一次送入很长的音频时，检测器只会切出最后一段
        let step = AudioMath.sampleRate / 10
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + step)
            segments += vad.acceptSegments(Array(samples[offset..<end]))
            offset = end
        }
        segments += vad.flushSegments()
        let rate = Double(AudioMath.sampleRate)
        // 检测器确认开始说话时，这句话已经开始了一小会儿；往前多取 0.3 秒，免得吞掉开头的字
        // （录音一开头就有人说话时最明显）
        let padding = AudioMath.sampleRate * 3 / 10
        return segments.map { segment in
            let start = max(0, segment.start - padding)
            let end = min(samples.count, segment.start + segment.samples.count)
            return Piece(start: Double(start) / rate, samples: Array(samples[start..<end]))
        }
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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
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
        stdout.fileHandleForReading.readabilityHandler = { handle in
            for line in String(decoding: handle.availableData, as: UTF8.self).split(whereSeparator: \.isNewline) {
                handleLine(String(line), output)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            for line in String(decoding: handle.availableData, as: UTF8.self).split(whereSeparator: \.isNewline) {
                handleLine(String(line), errors)
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
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
