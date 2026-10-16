import Foundation
import Testing
@testable import TidytalkCore

@Suite struct CaptionTests {
    @Test func partialIsReplacedByCommittedSentence() {
        var captions = CaptionTranscript()
        captions.partial = "大家好"
        #expect(captions.text == "大家好")
        captions.commit("大家好，今天开会。")
        #expect(captions.partial.isEmpty)
        captions.partial = "first"
        #expect(captions.text == "大家好，今天开会。first")
    }

    @Test func latinSentencesAreSpaced() {
        var captions = CaptionTranscript()
        captions.commit("Hello everyone.")
        captions.commit("Let's start.")
        #expect(captions.text == "Hello everyone. Let's start.")
    }

    @Test func oldSentencesAreDropped() {
        var captions = CaptionTranscript(limit: 10)
        for sentence in ["一二三四五", "六七八九十", "甲乙丙丁戊", "己庚辛壬癸"] { captions.commit(sentence) }
        #expect(captions.sentences.map(\.text) == ["甲乙丙丁戊", "己庚辛壬癸"])
        captions.commit("  ")
        #expect(captions.sentences.count == 2)
    }

    @Test func listenFieldsRoundTrip() throws {
        let config = AppConfig(listenSource: "com.google.Chrome", captionSize: .large, captionAutoHide: false)
        #expect(try AppConfig.decode(config.encode()) == config)
        let defaults = try AppConfig.decode(Data("{}".utf8))
        #expect(defaults.listenSource.isEmpty && defaults.captionSize == .medium && defaults.captionAutoHide)
        #expect(defaults.captionStyle == .dark)
    }

    @Test func translationsAttachToTheirSentence() {
        var captions = CaptionTranscript()
        let first = captions.commit("Hello everyone.")!
        let second = captions.commit("Let's start.")!
        let marked = captions.markTranslating(second)
        #expect(marked)
        captions.setTranslation("大家好。", for: first)
        #expect(captions.sentence(first)?.translation == "大家好。")
        #expect(captions.sentence(second)?.isTranslating == true)
        captions.setTranslation(nil, for: second)
        #expect(captions.sentence(second)?.isTranslating == false)
        #expect(captions.text == "Hello everyone. Let's start.")
        let empty = captions.commit("")
        #expect(empty == nil)
    }

    @Test func skipsSentencesAlreadyInTheTargetLanguage() {
        #expect(!CaptionTranslation.needsTranslation("大家好，今天开会。", to: .simplifiedChinese))
        #expect(CaptionTranslation.needsTranslation("Good morning everyone.", to: .simplifiedChinese))
        #expect(!CaptionTranslation.needsTranslation("Good morning everyone.", to: .english))
        #expect(CaptionTranslation.needsTranslation("大家好", to: .english))
        #expect(CaptionTranslation.needsTranslation("大家好", to: .japanese))
        #expect(!CaptionTranslation.needsTranslation("おはようございます", to: .japanese))
        #expect(!CaptionTranslation.needsTranslation("hello", to: .original))
    }

    @Test func translationOutputIsCleaned() {
        #expect(CaptionTranslation.validate(original: "Hello.", translated: "<sentence>\n你好。\n</sentence>") == "你好。")
        #expect(CaptionTranslation.validate(original: "Hello.", translated: "Hello.") == nil)
        #expect(CaptionTranslation.validate(original: "Hi", translated: "  ") == nil)
        let messages = CaptionTranslation.messages(for: "Hi", context: ["Before"], language: .simplifiedChinese)
        #expect(messages.last?.content == "<context>\nBefore\n</context>\n<sentence>\nHi\n</sentence>")
    }

    @Test func captionLanguageFollowsTheSystem() {
        #expect(OutputLanguage.captionDefault(preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(OutputLanguage.captionDefault(preferredLanguages: ["zh-Hant-TW"]) == .traditionalChinese)
        #expect(OutputLanguage.captionDefault(preferredLanguages: ["ja-JP"]) == .japanese)
        #expect(OutputLanguage.captionDefault(preferredLanguages: ["pt-BR"]) == .english)
        #expect(AppConfig(captionLanguage: .original).captionLanguage.isTranslation)
        let config = AppConfig(captionTranslate: true, captionLanguage: .german, captionStyle: .glass)
        #expect(try! AppConfig.decode(config.encode()) == config)
    }

    @Test func recentPassageStopsAtALongPause() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var captions = CaptionTranscript()
        captions.commit("一。", start: t0, end: t0.addingTimeInterval(2))
        // 停了 5 秒
        captions.commit("二。", start: t0.addingTimeInterval(7), end: t0.addingTimeInterval(9))
        captions.commit("三。", start: t0.addingTimeInterval(9.5), end: t0.addingTimeInterval(12))
        captions.partial = "四"
        #expect(captions.recentPassage(now: t0.addingTimeInterval(13)) == "二。三。四")
    }

    @Test func recentPassageIsCappedAtThirtySeconds() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var captions = CaptionTranscript()
        for i in 0..<10 {
            let start = t0.addingTimeInterval(Double(i) * 5)
            captions.commit("第\(i)句。", start: start, end: start.addingTimeInterval(4.5))
        }
        // 现在是第 50 秒：只取 20 秒之后开始的句子
        #expect(captions.recentPassage(now: t0.addingTimeInterval(50)) == "第4句。第5句。第6句。第7句。第8句。第9句。")
        // 只有很久以前的一句时也能取到
        var single = CaptionTranscript()
        single.commit("Hello.", start: t0, end: t0.addingTimeInterval(1))
        #expect(single.recentPassage(now: t0.addingTimeInterval(100)) == "Hello.")
    }

    @Test func passageFromAClickedSentence() {
        var captions = CaptionTranscript()
        captions.commit("One.")
        let second = captions.commit("Two.")
        captions.commit("Three.")
        captions.partial = "four"
        #expect(captions.passage(from: second) == "Two. Three. four")
        #expect(captions.passage(from: nil) == "four")
    }
}
