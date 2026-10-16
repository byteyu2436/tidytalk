import Foundation
import Testing
@testable import TidytalkCore

@Suite struct VocabularyTests {
    @Test func replacesChinese() {
        #expect(Vocabulary.applyReplacements(["克劳德": "Claude"], to: "我在用克劳德写代码") == "我在用Claude写代码")
    }

    @Test func englishIsCaseInsensitiveWholeWord() {
        let rules = ["sense voice": "SenseVoice", "ai": "AI"]
        #expect(Vocabulary.applyReplacements(rules, to: "Sense Voice is an ai model") == "SenseVoice is an AI model")
        #expect(Vocabulary.applyReplacements(rules, to: "send an email") == "send an email")
    }

    @Test func longerMatchWinsAndNoChaining() {
        let rules = ["克劳德": "Claude", "克劳德代码": "Claude Code", "claude": "Claude Code"]
        // 只替换一次，"克劳德" 替换出来的 Claude 不会再被 "claude" 规则替换
        #expect(Vocabulary.applyReplacements(rules, to: "克劳德代码和克劳德") == "Claude Code和Claude")
    }

    @Test func normalizeDropsBlanksAndDuplicates() {
        #expect(Vocabulary.normalize([" Claude ", "", "claude", "张三"]) == ["Claude", "张三"])
    }

    @Test func promptIncludesVocabularyAndStyle() {
        let prompt = TranscriptCleanup.systemPrompt(style: .casual, vocabulary: ["Claude", "张三"])
        #expect(prompt.contains("Claude、张三"))
        #expect(prompt.contains("聊天"))
        #expect(TranscriptCleanup.systemPrompt() == TranscriptCleanup.systemPrompt)
    }

    @Test func vocabularyCorrectionPassesValidation() {
        // 中文音译被纠正成英文词，按词计数不应被判定为"变长"
        let raw = "我们用克劳德和森斯沃伊斯做了一个德莫"
        let cleaned = "我们用 Claude 和 SenseVoice 做了一个 demo。"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: cleaned) == cleaned)
    }
}

@Suite struct CleanupModeTests {
    @Test func configRoundTripsNewFields() throws {
        let config = AppConfig(typography: false, vocabulary: ["Claude"], replacements: ["克劳德": "Claude"],
                               style: .formal)
        #expect(try AppConfig.decode(config.encode()) == config)
    }

    @Test func unknownModeFallsBackToStandard() throws {
        let data = Data(#"{"style": "shouting", "vocabulary": ["x", 1]}"#.utf8)
        let config = try AppConfig.decode(data)
        #expect(config.style == .standard)
        #expect(config.vocabulary == ["x"])
        #expect(config.typography)
    }

    @Test func legacyAppStylesRemovedOnSave() throws {
        let old = Data(#"{"app_styles": {"com.tencent.xinWeChat": "casual"}, "extra": 1}"#.utf8)
        let data = try AppConfig.decode(old).encode(merging: old)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["app_styles"] == nil)
        #expect(root["extra"] as? Int == 1)
        #expect(root["style"] as? String == "standard")
    }

    @Test func modeChangesPrompt() {
        #expect(TranscriptCleanup.systemPrompt(style: .standard) == TranscriptCleanup.systemPrompt)
        for style in CleanupStyle.allCases where style != .standard {
            #expect(TranscriptCleanup.systemPrompt(style: style) != TranscriptCleanup.systemPrompt)
        }
    }

    @Test func pipelineSkipsTypographyWhenDisabled() {
        var config = AppConfig()
        #expect(TextPipeline.finish("用API", config: config, style: .standard) == "用 API")
        config.typography = false
        #expect(TextPipeline.finish("用API", config: config, style: .standard) == "用API")
    }
}
