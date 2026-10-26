import Foundation
import TidytalkCore

/// 会议录音：同时录麦克风（自己）和电脑的声音（会议里的其他人），各写一条音轨。
///
/// 两条音轨用同一个时间轴：从会议开始算起的样本序号。采集中断（换耳机、麦克风断开重连）的那段时间按真实时间补成静音，
/// 所以两条音轨、会议中识别出的每句话的时间、会后说话人分离的结果始终对得上。
@MainActor
final class MeetingRecorder {
    /// 一段新录到的音频：哪一路、在音轨里的起点（样本序号）。在音频线程上回调，同一路按顺序到达。
    struct Chunk: Sendable {
        let source: MeetingSource
        let start: Int
        let samples: [Float]
    }

    /// 录音中出现的问题（麦克风断开、收不到电脑声音），会议照常继续。
    var onWarning: ((String) -> Void)?
    /// 0...1 的电平，在主线程上回调。
    var onLevel: ((MeetingSource, Float) -> Void)?

    private let tracks: [MeetingSource: Track]
    private var mic: MicStream?
    private var system: SystemAudioCapture?
    private var outputObservation: OutputDeviceObservation?
    private var restartTask: Task<Void, Never>?
    private var appBundleID = ""
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private(set) var isRunning = false

    /// 插拔 AirPods 时新设备可能还没准备好：稍等一下再试，几次都不行才报告。
    private static let restartDelays: [Duration] = [.milliseconds(300), .milliseconds(700), .milliseconds(1500)]

    init(micURL: URL, systemURL: URL, onChunk: @escaping @Sendable (Chunk) -> Void) throws {
        let start = ProcessInfo.processInfo.systemUptime
        tracks = [
            .microphone: Track(source: .microphone, writer: try MeetingAudioWriter(url: micURL), startUptime: start,
                               onChunk: onChunk),
            .system: Track(source: .system, writer: try MeetingAudioWriter(url: systemURL), startUptime: start,
                           onChunk: onChunk),
        ]
    }

    /// 录了多久（按真实时间）。
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startUptime }

    /// - Parameters:
    ///   - micDevice: 麦克风的设备 UID，空字符串表示系统默认。
    ///   - appBundleID: 只录某个应用的声音（例如 Zoom），空字符串表示电脑的全部声音（不含 Tidytalk 自己的提示音）。
    func start(micDevice: String, appBundleID: String) throws {
        self.appBundleID = appBundleID
        let micTrack = tracks[.microphone]!
        let mic = MicStream(onSamples: { micTrack.receive($0) },
                            onLevel: { [weak self] level in
                                MainActor.assumeIsolated { self?.onLevel?(.microphone, level) }
                            })
        mic.onFailure = { [weak self] message in self?.onWarning?(message) }
        try mic.start(deviceUID: micDevice, echoCancellation: true)
        self.mic = mic
        isRunning = true
        if !startSystem() {
            onWarning?(String(localized: "收不到电脑的声音，会议只录到你自己的声音"))
        }
        outputObservation = SystemAudioCapture.observeOutputDeviceChanges { [weak self] in
            Task { @MainActor in self?.scheduleSystemRestart() }
        }
    }

    /// 回声消除实际有没有打开。
    var echoCancellationActive: Bool { mic?.echoCancellationActive ?? false }

    /// 停止录音，写完文件。返回音轨长度（秒），两路取较长的一路。
    @discardableResult
    func stop() -> TimeInterval {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        outputObservation?.cancel()
        outputObservation = nil
        mic?.stop()
        mic = nil
        system?.stop()
        system = nil
        // 两路补齐到同样长：一路中途断了，另一路还在录
        let total = Int(elapsed * Double(AudioMath.sampleRate))
        for track in tracks.values { track.finish(padTo: total) }
        return tracks.values.map { Double($0.writer.sampleCount) / Double(AudioMath.sampleRate) }.max() ?? 0
    }

    private func startSystem() -> Bool {
        let track = tracks[.system]!
        let capture = SystemAudioCapture { samples in track.receive(samples) }
        capture.onNeedsRestart = { [weak self] in
            Task { @MainActor in self?.scheduleSystemRestart() }
        }
        do {
            try capture.start(appBundleID: appBundleID)
            system = capture
            return true
        } catch {
            return false
        }
    }

    /// 输出设备或格式变了：重新收听电脑的声音，失败时重试。
    private func scheduleSystemRestart() {
        guard isRunning else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            for delay in Self.restartDelays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, isRunning else { return }
                system?.stop()
                system = nil
                if startSystem() {
                    restartTask = nil
                    return
                }
            }
            self?.restartTask = nil
            self?.onWarning?(String(localized: "收不到电脑的声音，会议只录到你自己的声音"))
        }
    }
}

/// 一路音轨：按到达顺序写盘，并把音频连同在音轨里的位置交给识别。
private final class Track: @unchecked Sendable {
    let source: MeetingSource
    let writer: MeetingAudioWriter
    private let startUptime: TimeInterval
    private let onChunk: @Sendable (MeetingRecorder.Chunk) -> Void
    private let lock = NSLock()

    /// 落后真实时间超过这么多才补静音：音频本来就是一块一块到的，正常的抖动不用管。
    private static let gapTolerance = AudioMath.sampleRate / 2

    init(source: MeetingSource, writer: MeetingAudioWriter, startUptime: TimeInterval,
         onChunk: @escaping @Sendable (MeetingRecorder.Chunk) -> Void) {
        self.source = source
        self.writer = writer
        self.startUptime = startUptime
        self.onChunk = onChunk
    }

    func receive(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            // 这一块应该从哪里开始：现在的时间减去它的长度
            let now = ProcessInfo.processInfo.systemUptime
            let expected = Int((now - startUptime) * Double(AudioMath.sampleRate)) - samples.count
            let gap = expected - writer.sampleCount
            if gap > Self.gapTolerance {
                let silence = [Float](repeating: 0, count: gap)
                let start = writer.sampleCount
                writer.append(silence)
                onChunk(.init(source: source, start: start, samples: silence))
            }
            let start = writer.sampleCount
            writer.append(samples)
            onChunk(.init(source: source, start: start, samples: samples))
        }
    }

    func finish(padTo total: Int) {
        lock.withLock {
            writer.appendSilence(total - writer.sampleCount)
            writer.finish()
        }
    }
}
