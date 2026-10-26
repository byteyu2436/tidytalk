import Foundation
import Testing
@testable import TidytalkApp
import TidytalkCore

/// 转写记录的存储：链接下载的音频留在记录里，可以单独删除；本机文件只记位置。
@MainActor
@Suite struct TranscriptionStoreTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    static func link() -> Transcription {
        var item = Transcription(kind: .link, title: "视频标题", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 state: .finished, model: "SenseVoice", link: "https://www.youtube.com/watch?v=x",
                                 segments: [TranscriptSegment(id: 0, start: 1, end: 2, text: "大家好")])
        item.audioFile = "audio.m4a"
        item.thumbnailFile = "thumbnail.jpg"
        return item
    }

    @Test func recordsRoundTripAndArePrivate() throws {
        let store = TranscriptionStore(root: directory.url)
        var item = Self.link()
        try store.create(item)
        item.updateText(of: 0, to: "大家好。")
        try store.save(item)

        let reopened = TranscriptionStore(root: directory.url)
        #expect(reopened.items == [item])
        let folder = store.directory(for: item.id)
        #expect(folder.posixPermissions == 0o700)
        #expect(folder.appending(path: "transcription.json").posixPermissions == 0o600)
    }

    @Test func newestFirstAndSplitByKind() throws {
        let store = TranscriptionStore(root: directory.url)
        var older = Self.link()
        older.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Self.link()
        let file = Transcription(kind: .file, title: "周会", createdAt: Date(timeIntervalSince1970: 1_750_000_000),
                                 state: .finished, model: "SenseVoice", sourcePath: "/tmp/周会.mp3")
        for item in [older, newer, file] { try store.create(item) }
        let broken = directory.url.appending(path: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appending(path: "transcription.json"))

        let reopened = TranscriptionStore(root: directory.url)
        #expect(reopened.items.map(\.id) == [newer.id, file.id, older.id])
        #expect(reopened.items(of: .link).map(\.id) == [newer.id, older.id])
        #expect(reopened.items(of: .file).map(\.id) == [file.id])
        // 坏文件没有被删
        #expect(FileManager.default.fileExists(atPath: broken.appending(path: "transcription.json").path))
    }

    @Test func deletingAudioKeepsTextAndThumbnail() throws {
        let store = TranscriptionStore(root: directory.url)
        let item = Self.link()
        try store.create(item)
        let folder = store.directory(for: item.id)
        try Data([1, 2, 3]).write(to: folder.appending(path: "audio.m4a"))
        try Data([4]).write(to: folder.appending(path: "thumbnail.jpg"))
        #expect(store.audioURL(item) != nil)

        store.deleteAudio(item.id)
        let reopened = TranscriptionStore(root: directory.url)
        let saved = try #require(reopened.item(item.id))
        #expect(saved.audioFile == nil)
        #expect(saved.segments.count == 1)
        #expect(reopened.audioURL(saved) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "thumbnail.jpg").path))

        store.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(TranscriptionStore(root: directory.url).items.isEmpty)
    }

    @Test func localFileIsPlayedFromWhereItIsAndDeletingKeepsIt() throws {
        let store = TranscriptionStore(root: directory.url)
        let original = directory.url.appending(path: "原文件.mp3")
        try Data([1]).write(to: original)
        let item = Transcription(kind: .file, title: "原文件", state: .finished, model: "SenseVoice",
                                 sourcePath: original.path)
        try store.create(item)
        #expect(store.audioURL(item) == original)
        store.delete(item.id)
        #expect(FileManager.default.fileExists(atPath: original.path))

        // 原文件被移走后不能播放
        try FileManager.default.removeItem(at: original)
        #expect(store.audioURL(item) == nil)
    }

    @Test func interruptedTranscriptionIsMarkedOnReload() throws {
        let store = TranscriptionStore(root: directory.url)
        let empty = Transcription(kind: .file, title: "空", state: .transcribing, model: "SenseVoice")
        var started = Transcription(kind: .file, title: "一半", state: .transcribing, model: "SenseVoice")
        started.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "前面")]
        try store.create(empty)
        try store.create(started)

        let reopened = TranscriptionStore(root: directory.url)
        #expect(reopened.item(empty.id)?.state == .failed)
        #expect(reopened.item(empty.id)?.error != nil)
        #expect(reopened.item(started.id)?.state == .finished)
        #expect(reopened.item(started.id)?.isPartial == true)
    }

    @Test func parsesYTDLPOutput() {
        let result = YTDLP.parse(["[info] something", "视频标题", "某个频道", "/tmp/x/audio.m4a"])
        #expect(result == YTDLP.Download(file: URL(fileURLWithPath: "/tmp/x/audio.m4a"), title: "视频标题",
                                         uploader: "某个频道"))
        // 网站没有上传者时 yt-dlp 输出 NA
        #expect(YTDLP.parse(["标题", "NA", "/tmp/a.m4a"])?.uploader == nil)
        #expect(YTDLP.parse(["/tmp/a.m4a"]) == nil)
        #expect(YTDLP.parse(["标题", "NA", "ERROR: failed"]) == nil)
    }

    @Test func findsThumbnail() throws {
        try Data([1]).write(to: directory.url.appending(path: "audio.m4a"))
        #expect(YTDLP.thumbnail(in: directory.url) == nil)
        try Data([1]).write(to: directory.url.appending(path: "thumbnail.webp"))
        #expect(YTDLP.thumbnail(in: directory.url)?.lastPathComponent == "thumbnail.webp")
    }
}
