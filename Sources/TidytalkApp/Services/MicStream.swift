@preconcurrency import AVFoundation
import Foundation
import TidytalkCore

/// 会议模式的麦克风：持续把 16 kHz 单声道音频交出去，没有时长上限，也不在内存里攒着（说话输入用 `AudioRecorder`）。
///
/// - 可以打开系统的回声消除（voice processing），不戴耳机时少录进扬声器里对方的声音；打不开时照常录音。
/// - 换麦克风、格式变化时引擎会停下，重新建一个继续录；超过几秒没有收到数据（麦克风断开）也会重试。
///   中断的那段时间由 `MeetingRecorder` 按真实时间补成静音，和电脑声音那一路保持对齐。
@MainActor
final class MicStream {
    /// 重试几次都打不开麦克风时回调，会议照常继续（只是录不到自己的声音）。
    var onFailure: ((String) -> Void)?

    private let feed: MicFeed
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var deviceUID = ""
    private var wantsEchoCancellation = true
    private var restartAttempts = 0
    /// 回声消除实际有没有打开（有的麦克风不支持）。
    private(set) var echoCancellationActive = false

    /// 超过这么久没有收到数据就认为麦克风断开了，重新打开。
    private static let silenceLimit: TimeInterval = 2.5
    private static let maxRestartAttempts = 5

    /// - Parameters:
    ///   - onSamples: 在音频线程上回调。
    ///   - onLevel: 0...1 的电平，在主线程上回调。
    init(onSamples: @escaping @Sendable ([Float]) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        feed = MicFeed(onSamples: onSamples, onLevel: onLevel)
    }

    var isRunning: Bool { engine != nil }

    func start(deviceUID: String, echoCancellation: Bool) throws {
        self.deviceUID = deviceUID
        wantsEchoCancellation = echoCancellation
        restartAttempts = 0
        try openEngine()
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        closeEngine()
    }

    private func openEngine() throws {
        closeEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AudioDevices.device(uid: deviceUID) {
            try input.auAudioUnit.setDeviceID(device.id)
        }
        echoCancellationActive = false
        if wantsEchoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // 回声消除默认会把其他应用的声音压低，会议里正需要听清对方，尽量不压
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                echoCancellationActive = true
            } catch {
                // 这个麦克风不支持：不消除回声，会后按内容去重（MeetingAlignment.removingEcho）
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorder.RecorderError.noInputDevice }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw AudioRecorder.RecorderError.unsupportedFormat }
        feed.reset(converter: converter, target: target)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: format,
                         block: feed.makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
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

    /// 设备或格式变了、或者很久没有数据：整个重新打开。失败时稍后再试，几次都不行就放弃。
    private func restart() {
        guard watchdog != nil else { return }
        do {
            try openEngine()
            restartAttempts = 0
        } catch {
            restartAttempts += 1
            if restartAttempts >= Self.maxRestartAttempts {
                stop()
                onFailure?(String(localized: "麦克风断开了，会议只录到电脑的声音"))
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let last = self.feed.lastDataUptime
                if ProcessInfo.processInfo.systemUptime - last > Self.silenceLimit { self.restart() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        feed.touch()
    }
}

/// 在音频线程上转换格式、交出数据。
private final class MicFeed: @unchecked Sendable {
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var lastData: TimeInterval = 0

    init(onSamples: @escaping @Sendable ([Float]) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    func reset(converter: AVAudioConverter, target: AVAudioFormat) {
        lock.withLock {
            self.converter = converter
            self.target = target
            lastData = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 刚开始或刚重启时，从现在开始计算"多久没有数据"。
    func touch() {
        lock.withLock { lastData = ProcessInfo.processInfo.systemUptime }
    }

    var lastDataUptime: TimeInterval { lock.withLock { lastData } }

    /// 闭包必须在非隔离的上下文中创建，否则 Swift 6 会把它当成主线程隔离，被音频线程调用时崩溃。
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in append(buffer) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let (converter, target) = lock.withLock { (self.converter, self.target) }
        guard let converter, let target, buffer.format == converter.inputFormat else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { lastData = now }
        onSamples(samples)
        let level = AudioMath.level(fromRMS: AudioMath.rms(samples[...]))
        let onLevel = onLevel
        DispatchQueue.main.async { onLevel(level) }
    }
}
