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
    /// 麦克风送来了第一段真正的声音（不全是 0）。蓝牙耳机要先切到通话模式，可能要等一两秒。
    var onInputReady: (() -> Void)?

    private var engine: AVAudioEngine?
    private var sink: SampleSink?
    private var deviceUID = ""
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var startedUptime: TimeInterval = 0
    private var lastRestartUptime: TimeInterval?
    private var restarts = 0

    /// 正在录音。中途重新打开麦克风失败、等待重试时也算（已经录到的保留在 sink 里）。
    var isRecording: Bool { sink != nil }

    /// - Parameter deviceUID: 指定的麦克风；为空或设备已断开时使用系统默认麦克风。
    func start(deviceUID: String = "") throws {
        guard sink == nil else { return }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false)
        else { throw RecorderError.unsupportedFormat }

        let maxSamples = Int(Self.maxDuration) * AudioMath.sampleRate
        let sink = SampleSink(targetFormat: target, maxSamples: maxSamples,
                              onLevel: { [weak self] level in
                                  MainActor.assumeIsolated { self?.onLevel?(level) }
                              },
                              onLimit: { [weak self] in
                                  MainActor.assumeIsolated { self?.onLimitReached?() }
                              },
                              onSignal: { [weak self] sink in
                                  MainActor.assumeIsolated {
                                      // 上一次录音迟到的回调不算
                                      guard let self, sink === self.sink else { return }
                                      self.onInputReady?()
                                  }
                              })
        self.deviceUID = deviceUID
        // 从按下算起：蓝牙耳机切换模式时，启动引擎本身也可能要等一阵
        startedUptime = ProcessInfo.processInfo.systemUptime
        try openEngine(feeding: sink)
        self.sink = sink
        lastRestartUptime = nil
        restarts = 0
        startWatchdog()
    }

    /// 新建一个引擎接上麦克风。换了设备或格式之后旧引擎不一定能再启动（蓝牙耳机切换模式时尤其如此），
    /// 所以每次都新建，和会议的 `MicStream` 一样。
    private func openEngine(feeding sink: SampleSink) throws {
        closeEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AudioDevices.device(uid: deviceUID) {
            // 必须在读取输入格式和安装 tap 之前切换设备
            try input.auAudioUnit.setDeviceID(device.id)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: sink.targetFormat) else {
            throw RecorderError.unsupportedFormat
        }
        sink.replaceConverter(converter)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: format,
                         block: sink.makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // 录音中途换了麦克风或格式变了（AirPods 切到通话模式、拔掉 USB 麦克风）时引擎会停下，重新打开后继续录
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func closeEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// 重新打开麦克风，已经录到的音频保留在同一个 sink 里。打不开时（蓝牙耳机还在切换模式）由看门狗稍后再试。
    /// 次数用完就不再重开（设备一直报格式变化时不会没完没了地重建），结束时按断开处理。
    private func restart() {
        guard let sink, restarts < InputCheck.maxRestarts else { return }
        restarts += 1
        lastRestartUptime = ProcessInfo.processInfo.systemUptime
        // 打不开时 engine 留空，看门狗半秒后再试
        try? openEngine(feeding: sink)
    }

    /// 每半秒检查一次：上一次打开失败、或者引擎停了却没有发通知，就再试；很久没有数据也重新打开。
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sink else { return }
                if InputCheck.shouldRestart(started: self.startedUptime, lastData: sink.lastDataUptime,
                                            lastRestart: self.lastRestartUptime,
                                            running: self.engine?.isRunning == true,
                                            restarts: self.restarts, now: ProcessInfo.processInfo.systemUptime) {
                    self.restart()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// 麦克风断开后一直没有恢复：结束前一段时间没有收到任何声音数据（不是安静，而是根本没有数据）。
    /// 中途断开又恢复（重新打开成功）时不算，已经录到的内容照常使用。
    func lostInput() -> Bool {
        guard let sink else { return false }
        return InputCheck.lostInput(started: startedUptime, lastData: sink.lastDataUptime,
                                    now: ProcessInfo.processInfo.systemUptime)
    }

    /// 从开始录音到现在。
    var elapsed: TimeInterval {
        sink == nil ? 0 : ProcessInfo.processInfo.systemUptime - startedUptime
    }

    /// 从开始录音到收到第一段真正的声音（不全是 0）；还没收到时为 nil。
    var signalDelay: TimeInterval? {
        sink?.signalUptime.map { $0 - startedUptime }
    }

    /// 这次录音重新打开过几次麦克风（开发命令里查看）。
    var restartCount: Int { restarts }

    /// 结束录音并返回采集到的音频。
    func stop() -> [Float] {
        guard let sink else { return [] }
        watchdog?.invalidate()
        watchdog = nil
        closeEngine()
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

    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 开发用：模拟录音中途设备配置变化（AirPods 切到通话模式），检查重新打开后能接着录。
    func simulateConfigurationChange() {
        guard let engine else { return }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// 开发用：模拟引擎悄悄停下、没有发通知，检查看门狗会重新打开。
    func simulateStall() {
        engine?.stop()
    }
    #endif
}

/// 在音频线程上接收数据；回调统一派发到主线程。
final class SampleSink: @unchecked Sendable {
    private var converter: AVAudioConverter?
    let targetFormat: AVAudioFormat
    private let maxSamples: Int
    private let onLevel: @Sendable (Float) -> Void
    private let onLimit: @Sendable () -> Void
    private let onSignal: @Sendable (SampleSink) -> Void

    private let lock = NSLock()
    private var samples: [Float] = []
    private var limitReported = false
    private var lastData: TimeInterval?
    private var signal: TimeInterval?

    /// - Parameter onSignal: 收到第一段真正的声音（不全是 0）时回调一次。
    init(targetFormat: AVAudioFormat, maxSamples: Int,
         onLevel: @escaping @Sendable (Float) -> Void, onLimit: @escaping @Sendable () -> Void,
         onSignal: @escaping @Sendable (SampleSink) -> Void = { _ in }) {
        self.targetFormat = targetFormat
        self.maxSamples = maxSamples
        self.onLevel = onLevel
        self.onLimit = onLimit
        self.onSignal = onSignal
        samples.reserveCapacity(maxSamples)
    }

    /// 回调在音频线程上执行。闭包必须在非隔离的上下文中创建：如果写在 `@MainActor` 的
    /// `AudioRecorder.start()` 里，Swift 6 会把它推断为主线程隔离，并在运行时检查，
    /// 被音频线程调用时直接崩溃。
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in append(buffer) }
    }

    /// 每次打开麦克风时换用对应输入格式的转换器。
    func replaceConverter(_ converter: AVAudioConverter) {
        lock.withLock { self.converter = converter }
    }

    func append(_ buffer: AVAudioPCMBuffer, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // 设备切换的瞬间可能还收到旧格式的数据，格式对不上的丢掉
        guard let converter = lock.withLock({ self.converter }), buffer.format == converter.inputFormat else { return }
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
        // 蓝牙耳机切换模式期间可能先送来一段全是 0 的数据，不算真正的声音
        let firstSignal = signal == nil && InputCheck.firstSignal(in: chunk) != nil
        if firstSignal { signal = now }
        lock.unlock()

        let level = AudioMath.level(fromRMS: AudioMath.rms(chunk))
        let onLevel = onLevel, onLimit = onLimit, onSignal = onSignal
        DispatchQueue.main.async {
            onLevel(level)
            if firstSignal { onSignal(self) }
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

    /// 收到第一段真正的声音（不全是 0）的时间；还没收到时为 nil。
    var signalUptime: TimeInterval? { lock.withLock { signal } }
}
