import CSherpaOnnx
import Foundation
import TidytalkCore

/// 会后分说话人（sherpa-onnx：pyannote 分段 + CAM++ 声纹聚类）。
///
/// 整段音频一次处理，在 M 系列芯片上耗时约为音频长度的 6–10%（一小时会议约 4–6 分钟），
/// 处理开始后不能中途打断。不同说话人的结果可能在时间上重叠（几个人同时说话）。
final class SpeakerDiarizer: @unchecked Sendable {
    enum DiarizerError: LocalizedError {
        case createFailed

        var errorDescription: String? { String(localized: "说话人模型加载失败，请在设置里重新下载") }
    }

    /// 人数未知时的聚类阈值：越小分出的人越多。官方四人测试录音上 0.6–0.7 正好分出 4 个人，0.5 会多分出两个。
    static let defaultThreshold: Float = 0.7

    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "app.tidytalk.diarization", qos: .utility)

    init(directory: URL) throws {
        let segmentation = strdup(directory.appending(path: "segmentation.int8.onnx").path)
        let embedding = strdup(directory.appending(path: "embedding.onnx").path)
        let provider = strdup("cpu")
        defer { [segmentation, embedding, provider].forEach { free($0) } }
        let threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))

        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = UnsafePointer(segmentation)
        config.segmentation.num_threads = threads
        config.segmentation.provider = UnsafePointer(provider)
        config.embedding.model = UnsafePointer(embedding)
        config.embedding.num_threads = threads
        config.embedding.provider = UnsafePointer(provider)
        config.clustering.threshold = Self.defaultThreshold
        // 短于 0.3 秒的片段丢掉；同一个人停顿短于 0.5 秒的合成一段
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5
        guard let handle = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else { throw DiarizerError.createFailed }
        self.handle = handle
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(handle)
    }

    /// 分出每个人说话的时间段。
    /// - Parameters:
    ///   - speakers: 已知人数时传入（用户在界面上指定），否则按阈值自动判断。
    ///   - onProgress: 0...1，在后台线程上回调。
    func diarize(_ samples: [Float], speakers: Int? = nil,
                 onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [MeetingAlignment.Turn] {
        guard samples.count > AudioMath.sampleRate else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                // 0 表示用默认值（见 c-api.h），所以人数未知时传 -1
                config.clustering.num_clusters = Int32(speakers ?? -1)
                config.clustering.threshold = Self.defaultThreshold
                SherpaOnnxOfflineSpeakerDiarizationSetConfig(handle, &config)

                let box = Unmanaged.passRetained(ProgressBox(onProgress))
                defer { box.release() }
                let result = samples.withUnsafeBufferPointer { buffer in
                    SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                        handle, buffer.baseAddress, Int32(buffer.count),
                        { done, total, arg in
                            guard let arg, total > 0 else { return 0 }
                            Unmanaged<ProgressBox>.fromOpaque(arg).takeUnretainedValue()
                                .report(Double(done) / Double(total))
                            return 0
                        }, box.toOpaque())
                }
                guard let result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
                let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
                guard count > 0, let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else {
                    continuation.resume(returning: [])
                    return
                }
                defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }
                let turns = (0..<count).map { i in
                    MeetingAlignment.Turn(start: TimeInterval(segments[i].start), end: TimeInterval(segments[i].end),
                                          speaker: Int(segments[i].speaker))
                }
                continuation.resume(returning: turns)
            }
        }
    }
}

/// 把 Swift 闭包交给 C 回调（C 函数指针不能捕获上下文，只能通过 void* 参数传过去）。
private final class ProgressBox: @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double) { handler(fraction) }
}
