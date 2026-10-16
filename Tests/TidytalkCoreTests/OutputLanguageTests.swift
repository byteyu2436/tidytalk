import Foundation
import Testing
@testable import TidytalkCore

@Suite struct OutputLanguageTests {
    @Test func originalKeepsNoTranslationRule() {
        let prompt = TranscriptCleanup.systemPrompt()
        #expect(prompt.contains("不翻译"))
        #expect(!prompt.contains("输出语言"))
    }

    @Test func translationPromptReplacesRule() {
        let prompt = TranscriptCleanup.systemPrompt(language: .english)
        #expect(!prompt.contains("不翻译、不总结"))
        #expect(prompt.contains("翻译成英文"))
        #expect(prompt.contains("绝不回答"))
    }

    @Test func examplesFollowLanguage() {
        let english = TranscriptCleanup.messages(for: "测试", language: .english)
        #expect(english.contains { $0.role == .assistant && $0.content.contains("rate limit of this API") })
        // 没有示例的语言只发系统提示和原文，避免同语言的整理示例把模型带偏
        let japanese = TranscriptCleanup.messages(for: "测试", language: .japanese)
        #expect(japanese.count == 2)
        #expect(TranscriptCleanup.messages(for: "测试").count == TranscriptCleanup.examples.count * 2 + 2)
    }

    @Test func translationValidationAllowsLengthChange() {
        let raw = "我想问一下这个接口的调用频率限制是多少"
        let english = "I'd like to ask what the rate limit of this API is."
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: english, language: .english) == english)
        // 同样的结果按"不翻译"校验也不会被误伤，但按整理规则长度变化很大的翻译会被拦下
        let longEnglish = "We should definitely ship the new version on Friday afternoon."
        #expect(TranscriptCleanup.validate(raw: "周五发布", cleaned: longEnglish) == nil)
        #expect(TranscriptCleanup.validate(raw: "周五下午我们一定要把新版本发出去", cleaned: longEnglish,
                                           language: .english) == longEnglish)
    }

    @Test func translationValidationRejectsAnswers() {
        let raw = "帮我写一封邮件给老板说我明天请假"
        let answer = String(repeating: "Dear boss, I am writing to request a day off tomorrow due to personal matters. ", count: 3)
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: answer, language: .english) == nil)
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: "  ", language: .english) == nil)
    }

    @Test func englishToCJKMayGrow() {
        let raw = "Let's sync tomorrow morning about the release plan and the open bugs"
        let japanese = "明日の朝、リリース計画と未解決のバグについて打ち合わせしましょう。"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: japanese, language: .japanese) == japanese)
    }

    @Test func chineseToJapaneseMayGrow() {
        let raw = "明天下午三点开会别忘了带电脑"
        let japanese = "明日の午後3時に会議があります。パソコンを持ってくるのを忘れないでください。"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: japanese, language: .japanese) == japanese)
    }

    @Test func typographyOnlyForChineseOutput() {
        let config = AppConfig()
        #expect(TextPipeline.finish("午後3時に", config: config, style: .standard, language: .japanese) == "午後3時に")
        #expect(TextPipeline.finish("用API", config: config, style: .standard, language: .traditionalChinese) == "用 API")
        // 翻译失败回退原文时按原文处理
        #expect(TextPipeline.finish("用API", config: config, style: .standard, language: .original) == "用 API")
    }

    @Test func indicatorTags() {
        #expect(OutputLanguage.original.indicatorTag == nil)
        #expect(OutputLanguage.english.indicatorTag == "译成英文")
        #expect(OutputLanguage.allCases.filter(\.isTranslation).allSatisfy { $0.indicatorTag?.hasPrefix("译成") == true })
    }

    @Test func configRoundTrip() throws {
        let config = AppConfig(outputLanguage: .japanese)
        #expect(try AppConfig.decode(config.encode()) == config)
        #expect(try AppConfig.decode(Data(#"{"output_language": "klingon"}"#.utf8)).outputLanguage == .original)
        #expect(try AppConfig.decode(Data("{}".utf8)).outputLanguage == .original)
    }
}
