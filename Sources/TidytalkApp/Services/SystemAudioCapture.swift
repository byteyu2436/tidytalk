@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import TidytalkCore

/// 正在发出声音的应用，用于选择收听来源。
struct AudioSourceApp: Hashable, Sendable {
    let bundleID: String
    let name: String
}

/// Core Audio 里的进程对象：每个用到音频的进程（包括浏览器的辅助进程）各有一个。
enum AudioProcesses {
    struct Process {
        let id: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isPlaying: Bool
    }

    static func all() -> [Process] {
        ids().map(process)
    }

    /// 全部进程对象的编号，不查询各自的属性。
    static func ids() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func process(_ id: AudioObjectID) -> Process {
        Process(id: id,
                pid: value(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: bundleID(id),
                isPlaying: value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
    }

    static func bundleID(_ id: AudioObjectID) -> String {
        string(id, kAudioProcessPropertyBundleID) ?? ""
    }

    /// 本应用自己的进程对象（提示音），收听全部声音时排除掉。
    static func own() -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// 属于某个应用的进程：应用本身和它的辅助进程（例如 com.google.Chrome.helper）。
    /// Safari 等基于 WebKit 的应用由系统的 WebKit 进程发声，一并算进去。
    static func belongs(_ processBundleID: String, to appBundleID: String) -> Bool {
        processBundleID == appBundleID
            || processBundleID.hasPrefix(appBundleID + ".")
            || (appBundleID == "com.apple.Safari" && processBundleID.hasPrefix("com.apple.WebKit."))
    }

    /// 除了本应用以外，有没有进程正在发出声音。
    static func somethingElseIsPlaying() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return all().contains { $0.isPlaying && $0.pid != own }
    }

    /// 现在正在发出声音的应用（只列出普通应用，辅助进程归到所属的应用名下）。
    @MainActor
    static func playingApps() -> [AudioSourceApp] {
        let playing = all().filter(\.isPlaying).map(\.bundleID)
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != ownID,
                  playing.contains(where: { belongs($0, to: id) }), seen.insert(id).inserted
            else { return nil }
            return AudioSourceApp(bundleID: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 根据 bundle id 找应用名，应用没在运行时从磁盘上读取。
    @MainActor
    static func name(of bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : fallback
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }
}

/// 用 Core Audio 进程 tap 收听电脑发出的声音，转换为 16 kHz 单声道 Float32。
///
/// 第一次开始时 macOS 会询问是否允许"录制系统音频"；未允许时收到的是静音。
///
/// 状态只在主线程上修改（开始、停止、释放）；音频回调和属性监听在各自的队列上执行，只用创建时传进去的值，不碰这些状态。
@MainActor
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case failed(String, OSStatus)

        var errorDescription: String? { String(localized: "无法收听电脑声音") }
    }

    /// 收到的音频，在内部的串行队列上回调。
    private let onSamples: @Sendable ([Float]) -> Void
    private let queue = DispatchQueue(label: "app.tidytalk.system-audio", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?

    /// 需要重新开始收听时回调：声音格式变了（例如 AirPods 切到通话模式，采样率变了），
    /// 或者只听某个应用时它多了新的发声进程（浏览器后来才开的音频辅助进程）。
    var onNeedsRestart: (@Sendable () -> Void)?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var processListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "app.tidytalk.system-audio.listeners")

    init(onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    isolated deinit { stop() }

    var isRunning: Bool { procID != nil }

    /// - Parameter appBundleID: 只收听这个应用；为空时收听全部声音（不含本应用的提示音）。
    func start(appBundleID: String) throws {
        stop()
        do {
            try createTap(appBundleID: appBundleID)
            try createDevice()
            try startIO()
            watchForChanges(appBundleID: appBundleID)
        } catch {
            stop()
            throw error
        }
    }

    private static let formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func watchForChanges(appBundleID: String) {
        let restart = onNeedsRestart
        var address = Self.formatAddress
        let format = Self.formatListenerBlock(restart: restart)
        if AudioObjectAddPropertyListenerBlock(tapID, &address, listenerQueue, format) == noErr { formatListener = format }

        guard !appBundleID.isEmpty else { return }
        let processes = Self.processListenerBlock(appBundleID: appBundleID, known: Set(AudioProcesses.ids()),
                                                  restart: restart)
        var list = Self.processListAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, listenerQueue, processes)
            == noErr {
            processListener = processes
        }
    }

    func stop() {
        if let formatListener, tapID != kAudioObjectUnknown {
            var address = Self.formatAddress
            AudioObjectRemovePropertyListenerBlock(tapID, &address, listenerQueue, formatListener)
        }
        formatListener = nil
        if let processListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue,
                                                   processListener)
        }
        processListener = nil
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        converter = nil
    }

    private var tapUUID = UUID()

    private func createTap(appBundleID: String) throws {
        let description: CATapDescription
        if appBundleID.isEmpty {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: AudioProcesses.own().map { [$0] } ?? [])
        } else {
            let processes = AudioProcesses.all().filter { AudioProcesses.belongs($0.bundleID, to: appBundleID) }
            description = CATapDescription(monoMixdownOfProcesses: processes.map(\.id))
            // 应用退出后重新打开（或新开了辅助进程），按 bundle id 自动收听
            description.bundleIDs = Array(Set([appBundleID] + processes.map(\.bundleID).filter { !$0.isEmpty }))
            description.isProcessRestoreEnabled = true
        }
        description.name = "Tidytalk"
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw CaptureError.failed("create tap", status) }
        tapID = id
    }

    private func createDevice() throws {
        guard let outputUID = Self.defaultOutputUID() else { throw CaptureError.failed("output device", -1) }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tidytalk",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else { throw CaptureError.failed("create device", status) }
        deviceID = id
    }

    private func startIO() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw CaptureError.failed("tap format", status) }
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMath.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target)
        else { throw CaptureError.failed("format", -1) }
        converter.downmix = true
        self.converter = converter

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue,
                                                    Self.makeIOBlock(input: input, target: target, converter: converter,
                                                                     onSamples: onSamples))
        guard status == noErr, let proc else { throw CaptureError.failed("io proc", status) }
        procID = proc
        status = AudioDeviceStart(deviceID, proc)
        guard status == noErr else { throw CaptureError.failed("start", status) }
    }

    /// 监听回调在 listenerQueue 上执行，闭包必须在非隔离的上下文中创建：在主线程隔离的方法里创建的闭包，
    /// 被其他队列调用时 Swift 6 的运行时检查会直接崩溃（见 AudioRecorder 的 makeTapBlock）。
    nonisolated private static func formatListenerBlock(restart: (@Sendable () -> Void)?) -> AudioObjectPropertyListenerBlock {
        { _, _ in restart?() }
    }

    /// 只听某个应用时，有新的、属于这个应用的进程出现就重新开始。
    /// 全系统任何进程启动、退出都会触发这个监听，所以只查新出现的进程的 bundle id，不每次查全部。
    nonisolated private static func processListenerBlock(appBundleID: String, known: Set<AudioObjectID>,
                                                         restart: (@Sendable () -> Void)?) -> AudioObjectPropertyListenerBlock {
        let watch = ProcessWatch(known: known)
        return { _, _ in
            let added = watch.update(AudioProcesses.ids())
            if added.contains(where: { AudioProcesses.belongs(AudioProcesses.bundleID($0), to: appBundleID) }) {
                restart?()
            }
        }
    }

    /// 回调在音频队列上执行，闭包必须在非隔离的上下文中创建（见 AudioRecorder 的 makeTapBlock）。
    nonisolated private static func makeIOBlock(input: AVAudioFormat, target: AVAudioFormat, converter: AVAudioConverter,
                                    onSamples: @escaping @Sendable ([Float]) -> Void) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: inputData, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            let ratio = target.sampleRate / input.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
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
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
        }
    }

    static func defaultOutputUID() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return AudioProcesses.string(device, kAudioDevicePropertyDeviceUID)
    }

    /// 默认输出设备变化时（插拔耳机、连上 AirPods）回调，需要重新开始收听。
    static func observeOutputDevice(_ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            handler()
        }
    }

    /// 和 `observeOutputDevice` 一样，但可以移除：返回的对象调用 `cancel()` 或被释放时停止监听（会议模式每场会议挂一次）。
    static func observeOutputDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> OutputDeviceObservation {
        OutputDeviceObservation(handler)
    }
}

/// 默认输出设备变化的监听，`cancel()` 或释放时移除。
@MainActor
final class OutputDeviceObservation {
    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
    private var block: AudioObjectPropertyListenerBlock?

    fileprivate init(_ handler: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.address, .main, block)
            == noErr {
            self.block = block
        }
    }

    func cancel() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.address, .main, block)
        self.block = nil
    }

    isolated deinit { cancel() }
}

/// 记住已经见过的进程对象，只在 listenerQueue 这一个串行队列上使用。
private final class ProcessWatch: @unchecked Sendable {
    private var known: Set<AudioObjectID>

    init(known: Set<AudioObjectID>) {
        self.known = known
    }

    /// 返回这次新出现的进程。
    func update(_ ids: [AudioObjectID]) -> [AudioObjectID] {
        let current = Set(ids)
        let added = current.subtracting(known)
        known = current
        return Array(added)
    }
}
