import CoreAudio
import Foundation

/// 本机的音频输入设备（Core Audio）。
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// 设备的持久标识，拔插、重启后保持不变，用来保存用户的选择。
    let uid: String
    let name: String
    /// 连接方式（`kAudioDevicePropertyTransportType`）：内建、USB、蓝牙等。
    var transport: UInt32 = 0

    /// 蓝牙耳机的麦克风：每次打开都要先切到通话模式，开头一两秒没有声音，耳机的音质也会暂时变差。
    var isBluetooth: Bool { AudioDevices.isBluetooth(transport: transport) }
    /// Mac 自带的麦克风。
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum AudioDevices {
    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 开发用：截图时假装接着这些麦克风，第一个是系统默认的（`--settings-capture … --fake-bluetooth-mic`）。
    nonisolated(unsafe) static var simulated: [AudioInputDevice]?
    #endif

    static func inputDevices() -> [AudioInputDevice] {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        if let simulated { return simulated }
        #endif
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, transport: transportType(id))
        }
    }

    static func device(uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    /// 系统默认的输入设备（"系统设置 › 声音 › 输入"里选中的）。
    static func defaultInput() -> AudioInputDevice? {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        if let simulated { return simulated.first }
        #endif
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown
        else { return nil }
        return inputDevices().first { $0.id == id }
    }

    /// 录音时实际会用的麦克风：选中的已连接时用它，否则用系统默认的。
    static func effectiveInput(uid: String) -> AudioInputDevice? {
        device(uid: uid) ?? defaultInput()
    }

    static func isBluetooth(transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }
}
