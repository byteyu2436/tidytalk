import Foundation
import Testing
@testable import TidytalkCore

/// 转写记录：卡片上显示的来源、文件类型，改文字，导出时的文件名。
@Suite struct TranscriptionTests {
    @Test func hostDropsWWW() {
        let link = Transcription(kind: .link, title: "", model: "", link: "https://www.youtube.com/watch?v=1")
        #expect(link.host == "youtube.com")
        let mobile = Transcription(kind: .link, title: "", model: "", link: "https://m.bilibili.com/video/BV1")
        #expect(mobile.host == "bilibili.com")
        #expect(Transcription(kind: .file, title: "", model: "").host == nil)
    }

    @Test func fileTypeComesFromOriginalOrDownload() {
        let video = Transcription(kind: .file, title: "", model: "", sourcePath: "/Users/a/演示.mov")
        #expect(video.fileType == "MOV")
        #expect(video.isVideo)
        var link = Transcription(kind: .link, title: "", model: "", link: "https://example.com")
        #expect(link.fileType == nil)
        link.audioFile = "audio.m4a"
        #expect(link.fileType == "M4A")
        #expect(!link.isVideo)
    }

    @Test func editingKeepsTimingAndIgnoresBlank() {
        var item = Transcription(kind: .file, title: "", model: "",
                                 segments: [TranscriptSegment(id: 3, start: 1, end: 2, text: "原来")])
        item.updateText(of: 3, to: "  改过  ")
        #expect(item.segments == [TranscriptSegment(id: 3, start: 1, end: 2, text: "改过")])
        item.updateText(of: 3, to: "   ")
        #expect(item.segments[0].text == "改过")
        item.updateText(of: 9, to: "没有这一句")
        #expect(item.segments.count == 1)
    }

    @Test func exportNameAvoidsLinksAndSlashes() {
        #expect(Transcription(kind: .link, title: "https://x.com/a", model: "").exportName == "转写结果")
        #expect(Transcription(kind: .file, title: "a/b: c", model: "").exportName == "a-b- c")
    }

    @Test func roundTripsThroughJSON() throws {
        var item = Transcription(kind: .link, title: "标题", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 state: .finished, model: "SenseVoice", link: "https://example.com/v",
                                 segments: [TranscriptSegment(id: 0, start: 0.5, end: 1.5, text: "你好")])
        item.uploader = "频道"
        item.duration = 61
        item.audioFile = "audio.m4a"
        item.audioSize = 1024
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Transcription.self, from: encoder.encode(item)) == item)
    }
}
