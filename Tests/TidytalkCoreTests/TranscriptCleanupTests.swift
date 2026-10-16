import Testing
@testable import TidytalkCore

@Suite struct TranscriptCleanupTests {
    @Test func acceptsNormalCleanup() {
        let raw = "嗯那个我想问一下就是这个 API 的那个 rate limit 呃是多少"
        let cleaned = "我想问一下这个 API 的 rate limit 是多少？"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: cleaned) == cleaned)
    }

    @Test func acceptsCorrection() {
        let raw = "项目要延期到下周三，不对，是下周四"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: "项目要延期到下周四。") == "项目要延期到下周四。")
    }

    @Test func rejectsAnswer() {
        let raw = "帮我写一封邮件给老板说我明天请假"
        let answer = "好的，以下是邮件草稿：\n\n尊敬的老板：\n您好！我因个人原因明天需要请假一天，望批准。\n此致\n敬礼"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: answer) == nil)
    }

    @Test func rejectsSummary() {
        let raw = "我们今天下午开会主要讨论了三件事第一是下个版本的发布时间第二是测试的人手问题第三是文档要不要重写"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: "讨论了三件事。") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(TranscriptCleanup.validate(raw: "你好", cleaned: "  ") == nil)
        #expect(TranscriptCleanup.validate(raw: "你好", cleaned: "。") == nil)
    }

    @Test func shortFillerHeavyInputAllowed() {
        #expect(TranscriptCleanup.validate(raw: "嗯嗯那个好的", cleaned: "好的。") == "好的。")
    }

    @Test func sanitizesWrappers() {
        #expect(TranscriptCleanup.sanitize("```\n你好。\n```") == "你好。")
        #expect(TranscriptCleanup.sanitize("“你好。”") == "你好。")
        #expect(TranscriptCleanup.sanitize("<transcript>\n你好。\n</transcript>") == "你好。")
        #expect(TranscriptCleanup.sanitize("“甲”和“乙”") == "“甲”和“乙”")
    }

    @Test func significantCountIgnoresPunctuation() {
        #expect(TranscriptCleanup.significantCount("你好，API！ 1") == 4)
    }

    @Test func messagesEndWithTranscript() {
        let msgs = TranscriptCleanup.messages(for: "测试")
        #expect(msgs.first?.role == .system)
        #expect(msgs.last?.role == .user)
        #expect(msgs.last?.content.contains("测试") == true)
    }
}
