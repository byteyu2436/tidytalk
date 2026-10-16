@preconcurrency import AVFoundation
import TidytalkCore

/// 用 AVAudioEngine 录音，实时转换为 16 kHz 单声道 Float32。
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInputDevice: String(localized: "没有可用的麦克风")
            case .unsupportedFormat: String(localized: "麦克风格式不受支持")
            }
        }
    }

    static let maxDuration: TimeInterval = 120

    /// 0...1 电平，约每 50 ms 回调一次。
    var onLevel: ((Float) -> Void)?
    /// 达到最长录音时长。
    var onLimitReached: (() -> Void)?

    private var engine: AVAudioEngine?
    private var sink: SampleSink?

    var isRecording: Bool { engine != nil }

    /// - Parameter deviceUID: 指定的麦克风；为空或设备已断开时使用系统默认麦克风。
    func start(deviceUID: String = "") throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AudioDevices.device(uid: deviceUID) {
            // 必须在读取输入格式和安装 tap 之前切换设备
            try input.auAudioUnit.setDeviceID(device.id)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw RecorderError.unsupportedFormat }

        let maxSamples = Int(Self.maxDuration) * AudioMath.sampleRate
        let sink = SampleSink(converter: converter, targetFormat: target, maxSamples: maxSamples,
                              onLevel: { [weak self] level in
                                  MainActor.assumeIsolated { self?.onLevel?(level) }
                              },
                              onLimit: { [weak self] in
                                  MainActor.assumeIsolated { self?.onLimitReached?() }
                              })

        let frames = AVAudioFrameCount(inputFormat.sampleRate / 20)
        input.installTap(onBus: 0, bufferSize: frames, format: inputFormat, block: sink.makeTapBlock())

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.sink = sink
    }

    /// 结束录音并返回采集到的音频。
    func stop() -> [Float] {
        guard let engine, let sink else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.sink = nil
        return sink.drain()
    }

    /// 到目前为止录到的音频（不结束录音），用于实时预览。
    func recordedSamples() -> [Float] {
        sink?.drain() ?? []
    }

    func cancel() {
        _ = stop()
    }
}

/// 在音频线程上接收数据；回调统一派发到主线程。
private final class SampleSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let maxSamples: Int
    private let onLevel: @Sendable (Float) -> Void
    private let onLimit: @Sendable () -> Void

    private let lock = NSLock()
    private var samples: [Float] = []
    private var limitReported = false

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat, maxSamples: Int,
         onLevel: @escaping @Sendable (Float) -> Void, onLimit: @escaping @Sendable () -> Void) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.maxSamples = maxSamples
        self.onLevel = onLevel
        self.onLimit = onLimit
        samples.reserveCapacity(maxSamples)
    }

    /// 回调在音频线程上执行。闭包必须在非隔离的上下文中创建：如果写在 `@MainActor` 的
    /// `AudioRecorder.start()` 里，Swift 6 会把它推断为主线程隔离，并在运行时检查，
    /// 被音频线程调用时直接崩溃。
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in append(buffer) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))

        lock.lock()
        let room = maxSamples - samples.count
        samples.append(contentsOf: chunk.prefix(max(0, room)))
        let reachedLimit = samples.count >= maxSamples && !limitReported
        if reachedLimit { limitReported = true }
        lock.unlock()

        let level = AudioMath.level(fromRMS: AudioMath.rms(chunk))
        let onLevel = onLevel, onLimit = onLimit
        DispatchQueue.main.async {
            onLevel(level)
            if reachedLimit { onLimit() }
        }
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
