import AVFoundation
import CoreAudio
import Testing
@testable import TidytalkApp

/// 录音的数据接收（issue #1）：不录真的麦克风，用合成的音频块喂给 SampleSink。
@Suite struct SampleSinkTests {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                       interleaved: false)!
    private let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                      interleaved: false)!

    private func makeSink() -> SampleSink {
        let sink = SampleSink(targetFormat: target, maxSamples: 16_000 * 10, onLevel: { _ in }, onLimit: {})
        sink.replaceConverter(AVAudioConverter(from: input, to: target)!)
        return sink
    }

    /// 50 毫秒的音频块；`value` 为 0 时是全 0 的数据。
    private func buffer(_ format: AVAudioFormat, value: Float) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate / 20)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = value == 0 ? 0 : value * sin(Float(i) * 0.05)
        }
        return buffer
    }

    @Test func convertsToSixteenKilohertz() {
        let sink = makeSink()
        for i in 0..<10 { sink.append(buffer(input, value: 0.3), at: 100 + Double(i) * 0.05) }
        // 10 块 × 50 毫秒 = 0.5 秒；重采样器开头可能留一点在内部
        #expect(abs(sink.count - 8_000) < 200)
        #expect(sink.lastDataUptime == 100.45)
        #expect(sink.signalUptime == 100)
    }

    /// 蓝牙耳机切换到通话模式时先送来全 0 的数据：照样存下（保持时间对齐），但不算开始收音。
    @Test func zerosAreKeptButAreNotSignal() {
        let sink = makeSink()
        for i in 0..<5 { sink.append(buffer(input, value: 0), at: 100 + Double(i) * 0.05) }
        #expect(sink.count > 0)
        #expect(sink.lastDataUptime == 100.2)
        #expect(sink.signalUptime == nil)
        sink.append(buffer(input, value: 0.3), at: 101.4)
        #expect(sink.signalUptime == 101.4)
        sink.append(buffer(input, value: 0.3), at: 101.45)
        #expect(sink.signalUptime == 101.4)
    }

    /// 换设备的瞬间还会收到旧格式的数据：丢掉，也不算收到了数据。
    @Test func dropsBuffersInTheWrongFormat() {
        let sink = makeSink()
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        sink.append(buffer(other, value: 0.3), at: 100)
        #expect(sink.count == 0)
        #expect(sink.lastDataUptime == nil)
        // 重新打开后换成新格式的转换器，新格式的数据就能收下
        sink.replaceConverter(AVAudioConverter(from: other, to: target)!)
        sink.append(buffer(other, value: 0.3), at: 101)
        #expect(sink.count > 0)
        #expect(sink.signalUptime == 101)
    }

    @Test func ignoresDataBeforeTheMicrophoneIsOpened() {
        let sink = SampleSink(targetFormat: target, maxSamples: 16_000, onLevel: { _ in }, onLimit: {})
        sink.append(buffer(input, value: 0.3), at: 100)
        #expect(sink.count == 0)
        #expect(sink.lastDataUptime == nil)
    }

    @Test func stopsAtTheLimit() {
        let sink = SampleSink(targetFormat: target, maxSamples: 1_000, onLevel: { _ in }, onLimit: {})
        sink.replaceConverter(AVAudioConverter(from: input, to: target)!)
        for i in 0..<5 { sink.append(buffer(input, value: 0.3), at: 100 + Double(i) * 0.05) }
        #expect(sink.count == 1_000)
    }
}

@Suite struct AudioDevicesTests {
    @Test func bluetoothTransports() {
        #expect(AudioDevices.isBluetooth(transport: kAudioDeviceTransportTypeBluetooth))
        #expect(AudioDevices.isBluetooth(transport: kAudioDeviceTransportTypeBluetoothLE))
        #expect(!AudioDevices.isBluetooth(transport: kAudioDeviceTransportTypeBuiltIn))
        #expect(!AudioDevices.isBluetooth(transport: kAudioDeviceTransportTypeUSB))
        #expect(!AudioDevices.isBluetooth(transport: kAudioDeviceTransportTypeVirtual))
    }

    @Test func deviceFlags() {
        let airPods = AudioInputDevice(id: 1, uid: "a", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let mac = AudioInputDevice(id: 2, uid: "b", name: "MacBook Pro 麦克风", transport: kAudioDeviceTransportTypeBuiltIn)
        #expect(airPods.isBluetooth && !airPods.isBuiltIn)
        #expect(mac.isBuiltIn && !mac.isBluetooth)
    }
}
