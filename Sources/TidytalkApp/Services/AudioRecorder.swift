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
    private var deviceUID = ""
    private var configurationObserver: NSObjectProtocol?
    private var startedUptime: TimeInterval = 0

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
        self.deviceUID = deviceUID
        startedUptime = ProcessInfo.processInfo.systemUptime
        // 录音中途换了麦克风或格式变了（AirPods 切到通话模式、拔掉 USB 麦克风）时引擎会停下，重建后继续录
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterConfigurationChange() }
        }
    }

    /// 重新读取输入格式、换一个格式转换器、重装 tap 再启动；已经录到的音频保留在同一个 sink 里。
    private func rebuildAfterConfigurationChange() {
        guard let engine, let sink else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if let device = AudioDevices.device(uid: deviceUID) {
            try? input.auAudioUnit.setDeviceID(device.id)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: sink.targetFormat)
        else { return }
        sink.replaceConverter(converter)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: format,
                         block: sink.makeTapBlock())
        engine.prepare()
        try? engine.start()
    }

    /// 结束前这么久没有收到声音数据，就认为麦克风断开了。AirPods 切换模式时中断约 1～2 秒，但之后会恢复。
    private static let inputSilenceLimit: TimeInterval = 1.5

    /// 麦克风断开后一直没有恢复：最近一段时间没有收到任何声音数据（不是安静，而是根本没有数据）。
    /// 中途断开又恢复（切换设备重建成功）时不算，已经录到的内容照常使用。
    func lostInput() -> Bool {
        guard let sink else { return false }
        let lastData = sink.lastDataUptime ?? startedUptime
        return ProcessInfo.processInfo.systemUptime - lastData > Self.inputSilenceLimit
    }

    /// 结束录音并返回采集到的音频。
    func stop() -> [Float] {
        guard let engine, let sink else { return [] }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.sink = nil
        return sink.drain()
    }

    /// 到目前为止录到的音频（不结束录音）。
    func recordedSamples() -> [Float] {
        sink?.drain() ?? []
    }

    /// 从第 `offset` 个样本开始到目前为止录到的音频。只复制需要的部分：
    /// 整段复制会让音频线程下一次写入时把整个数组再复制一遍（最长约 7.7 MB）。
    func recordedSamples(from offset: Int) -> [Float] {
        sink?.samples(from: offset) ?? []
    }

    func cancel() {
        _ = stop()
    }
}

/// 在音频线程上接收数据；回调统一派发到主线程。
private final class SampleSink: @unchecked Sendable {
    private var converter: AVAudioConverter
    let targetFormat: AVAudioFormat
    private let maxSamples: Int
    private let onLevel: @Sendable (Float) -> Void
    private let onLimit: @Sendable () -> Void

    private let lock = NSLock()
    private var samples: [Float] = []
    private var limitReported = false
    private var lastData: TimeInterval?

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

    /// 输入设备变了以后换用新格式的转换器。
    func replaceConverter(_ converter: AVAudioConverter) {
        lock.withLock { self.converter = converter }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let converter = lock.withLock { self.converter }
        // 设备切换的瞬间可能还收到旧格式的数据，格式对不上的丢掉
        guard buffer.format == converter.inputFormat else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { lastData = now }
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

    func samples(from offset: Int) -> [Float] {
        lock.withLock { offset < samples.count ? Array(samples[max(0, offset)...]) : [] }
    }

    var count: Int { lock.withLock { samples.count } }

    /// 最近一次收到声音数据的时间（`systemUptime`）；还没收到过时为 nil。
    var lastDataUptime: TimeInterval? { lock.withLock { lastData } }
}
