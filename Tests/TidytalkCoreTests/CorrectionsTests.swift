import Foundation
import Testing
@testable import TidytalkCore

@Suite struct CorrectionsTests {
    @Test func findsAReplacedWord() {
        #expect(Corrections.find(original: "我们用克劳德写代码。", edited: "我们用 Claude 写代码。")
            == [WordCorrection(from: "克劳德", to: "Claude")])
        #expect(Corrections.find(original: "Let's ask cloud about it.", edited: "Let's ask Claude about it.")
            == [WordCorrection(from: "cloud", to: "Claude")])
    }

    @Test func singleCharacterFixesKeepTheirNeighbor() {
        #expect(Corrections.find(original: "这个用力要补一下", edited: "这个用例要补一下")
            == [WordCorrection(from: "用力", to: "用例")])
    }

    @Test func ignoresRewritesAdditionsAndPunctuation() {
        // 整句重写
        #expect(Corrections.find(original: "明天下午开会", edited: "后天上午不开会了，改成线上").isEmpty)
        // 只加了内容
        #expect(Corrections.find(original: "我们明天开会", edited: "我们明天下午开会").isEmpty)
        // 只改标点
        #expect(Corrections.find(original: "好的。谢谢", edited: "好的！谢谢").isEmpty)
        #expect(Corrections.find(original: "same", edited: "same").isEmpty)
    }

    @Test func locatesThePastedRegion() {
        let before = "Hi team,\n", after = "\nThanks"
        let value = "Hi team,\n我们用 Claude 写代码。\nThanks"
        #expect(Corrections.region(in: value, before: before, after: after) == "我们用 Claude 写代码。")
        #expect(Corrections.region(in: "abc", before: "", after: "") == "abc")
        #expect(Corrections.region(in: "abc", before: "zzz", after: "") == nil)
    }

    @Test func appleServiceRoundTrips() throws {
        var config = AppConfig(speechModel: .qwen3ASR, learnCorrections: false)
        config.ai = AIProvider.apple.applied(to: config.ai)
        #expect(config.ai.isConfigured && config.ai.isLocal && AIProvider.detect(config.ai) == .apple)
        #expect(try AppConfig.decode(config.encode()) == config)
        // 切回 Ollama 时恢复成 OpenAI 兼容接口
        #expect(AIProvider.ollama.applied(to: config.ai).service == .openAICompatible)
        let defaults = try AppConfig.decode(Data("{}".utf8))
        #expect(defaults.speechModel == .senseVoice && defaults.learnCorrections && defaults.ai.service == .openAICompatible)
    }
}

@Suite struct TranscriptExportTests {
    let segments = [
        TranscriptSegment(id: 0, start: 0.5, end: 3.2, text: "Hello everyone."),
        TranscriptSegment(id: 1, start: 3.6, end: 6, text: "Let's start."),
        TranscriptSegment(id: 2, start: 70, end: 3725.25, text: "大家好。"),
    ]

    @Test func plainTextBreaksParagraphsAtPauses() {
        #expect(TranscriptExport.render(segments, as: .text) == "Hello everyone. Let's start.\n\n大家好。\n")
    }

    @Test func srtUsesHoursAndMilliseconds() {
        let srt = TranscriptExport.render(segments, as: .srt)
        #expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:03,200\nHello everyone.\n"))
        #expect(srt.contains("3\n00:01:10,000 --> 01:02:05,250\n大家好。\n"))
    }

    @Test func markdownHasTitleAndClock() {
        let md = TranscriptExport.render(segments, as: .markdown, title: "Talk")
        #expect(md.hasPrefix("# Talk\n\n**0:00** Hello everyone."))
        #expect(TranscriptExport.clock(3725) == "1:02:05")
    }
}
