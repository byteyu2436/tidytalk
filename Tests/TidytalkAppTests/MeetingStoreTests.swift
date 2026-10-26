import AVFoundation
import Foundation
import Testing
@testable import TidytalkApp
import TidytalkCore

/// 会议的存储和录音文件（docs/meeting-mode.md）。
@MainActor
@Suite struct MeetingStoreTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    static func meeting() -> Meeting {
        Meeting(title: "周会", startedAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 12, state: .ready,
                segments: [MeetingSegment(id: 0, start: 1, end: 2, source: .microphone, speakerIDs: ["me"], text: "大家好")])
    }

    @Test func meetingsRoundTripAndArePrivate() throws {
        let store = MeetingStore(root: directory.url)
        var meeting = Self.meeting()
        try store.create(meeting)
        meeting.rename(speaker: "remote", to: "客户")
        try store.save(meeting)

        let reopened = MeetingStore(root: directory.url)
        #expect(reopened.meetings == [meeting])
        let folder = store.directory(for: meeting.id)
        #expect(folder.posixPermissions == 0o700)
        #expect(folder.appending(path: "meeting.json").posixPermissions == 0o600)
    }

    @Test func newestMeetingComesFirstAndBrokenFilesAreSkipped() throws {
        let store = MeetingStore(root: directory.url)
        var older = Self.meeting()
        older.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Self.meeting()
        try store.create(older)
        try store.create(newer)
        let broken = directory.url.appending(path: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appending(path: "meeting.json"))

        let reopened = MeetingStore(root: directory.url)
        #expect(reopened.meetings.map(\.id) == [newer.id, older.id])
        // 坏文件没有被删
        #expect(FileManager.default.fileExists(atPath: broken.appending(path: "meeting.json").path))
    }

    @Test func deletingRecordingKeepsText() throws {
        let store = MeetingStore(root: directory.url)
        let meeting = Self.meeting()
        try store.create(meeting)
        try Data([1, 2, 3]).write(to: store.audioURL(meeting.id, .microphone))
        store.deleteRecording(meeting.id)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(meeting.id, .microphone).path))
        #expect(MeetingStore(root: directory.url).meeting(meeting.id)?.hasRecording == false)
        #expect(MeetingStore(root: directory.url).meeting(meeting.id)?.segments.count == 1)

        store.delete(meeting.id)
        #expect(MeetingStore(root: directory.url).meetings.isEmpty)
    }

    // MARK: - 录音文件

    static func tone(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(AudioMath.sampleRate))).map { sin(Float($0) * 0.05) * 0.5 }
    }

    @Test func pcmIsReadableWithoutFinishing() async throws {
        let url = directory.url.appending(path: "mic.pcm")
        let writer = try MeetingAudioWriter(url: url)
        writer.append(Self.tone(seconds: 1))
        writer.appendSilence(AudioMath.sampleRate / 2)
        #expect(writer.sampleCount == AudioMath.sampleRate * 3 / 2)
        // 模拟应用崩溃：不调用 finish，只等写入队列把数据写下去
        try await Task.sleep(for: .milliseconds(200))
        let samples = try MeetingAudioWriter.readPCM(url)
        #expect(samples.count == AudioMath.sampleRate * 3 / 2)
        #expect(abs(samples[100] - Self.tone(seconds: 1)[100]) < 0.001)
        #expect(samples.last == 0)
        #expect(url.posixPermissions == 0o600)
        writer.finish()
    }

    @Test func readsASliceAndConvertsToM4A() throws {
        let pcm = directory.url.appending(path: "system.pcm")
        let writer = try MeetingAudioWriter(url: pcm)
        writer.appendSilence(AudioMath.sampleRate)
        writer.append(Self.tone(seconds: 2))
        writer.finish()

        let slice = try MeetingAudioWriter.readPCM(pcm, from: 1, to: 2)
        #expect(slice.count == AudioMath.sampleRate)
        #expect(slice.contains { abs($0) > 0.1 })

        let m4a = directory.url.appending(path: "system.m4a")
        try MeetingAudioWriter.convertToM4A(pcm, to: m4a)
        let file = try AVAudioFile(forReading: m4a)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 3) < 0.2)
        // 体积远小于 PCM（3 秒 PCM 约 96 KB）
        let size = try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int ?? 0
        #expect(size > 0 && size < 40_000)
    }

    @Test func modelManagerAcceptsAnySpec() {
        let manager = ModelManager(spec: .speakerDiarization)
        #expect(manager.totalSize == Int64(1_540_506 + 28_281_164))
        #expect(manager.directory.lastPathComponent == "speaker-diarization-pyannote3-campplus-zh-en")
    }
}
