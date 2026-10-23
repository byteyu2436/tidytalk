import Foundation
import Testing
@testable import TidytalkCore

@Suite struct ModelOutputTests {
    @Test func stripsThinkingBlock() {
        #expect(ModelOutput.stripReasoning("<think>\n用户想整理……\n</think>\n\n我想问一下。") == "我想问一下。")
        #expect(ModelOutput.stripReasoning("<THINKING>x</THINKING>好的") == "好的")
    }

    @Test func unfinishedThinkingIsFailure() {
        #expect(ModelOutput.stripReasoning("<think>还没想完") == nil)
    }

    @Test func plainAnswerUnchanged() {
        #expect(ModelOutput.stripReasoning("  项目延期到下周四。\n") == "项目延期到下周四。")
        #expect(ModelOutput.stripReasoning("a\u{200B}b") == "ab")
    }

    @Test func reasoningSwitchPerProvider() {
        #expect(ModelOutput.reasoningSwitch(forBaseURL: "https://api.deepseek.com/v1") == .deepSeek)
        #expect(ModelOutput.reasoningSwitch(forBaseURL: "https://openrouter.ai/api/v1") == .openRouter)
        #expect(ModelOutput.reasoningSwitch(forBaseURL: "http://localhost:11434/v1") == .effortNone)
    }
}

@Suite struct PasteReceiptsTests {
    @Test func restoresAfterQuietPeriodFollowingRead() {
        var r = PasteReceipts()
        r.pasting(at: 0)
        #expect(r.decision(at: 0.1) == .wait)
        r.read(at: 0.15)
        #expect(r.decision(at: 0.3) == .wait)
        r.read(at: 0.3)          // 先探测、再读取
        #expect(r.decision(at: 0.45) == .wait)
        #expect(r.decision(at: 0.5) == .restore)
    }

    @Test func slowAppStillGetsTheText() {
        var r = PasteReceipts()
        r.pasting(at: 0)
        // 应用卡了 2 秒才读取，固定等待 600 毫秒的做法会让它读到旧内容
        #expect(r.decision(at: 2) == .wait)
        r.read(at: 2.1)
        #expect(r.decision(at: 2.35) == .restore)
    }

    @Test func noReadEventuallyRestores() {
        var r = PasteReceipts()
        r.pasting(at: 0)
        #expect(r.decision(at: 3.9) == .wait)
        #expect(r.decision(at: 4.0) == .restore)
    }

    @Test func readBeforePasteFallsBackToFixedDelay() {
        var r = PasteReceipts()
        r.read(at: -0.05)        // 剪贴板管理工具抢先读了
        r.pasting(at: 0)
        #expect(r.decision(at: 0.5) == .wait)
        #expect(r.decision(at: 0.6) == .restore)
    }

    @Test func replacedContentIsKept() {
        var r = PasteReceipts()
        r.pasting(at: 0)
        r.read(at: 0.1)
        r.contentReplaced()
        #expect(r.decision(at: 1) == .keep)
    }
}

@Suite struct VocabularyMatcherTests {
    @Test func fixesCaseAndSpacing() {
        let terms = ["GitHub", "ChatGPT", "SenseVoice"]
        #expect(VocabularyMatcher.correct("代码放在 github 上", terms: terms) == "代码放在 GitHub 上")
        #expect(VocabularyMatcher.correct("问一下 chat gpt", terms: terms) == "问一下 ChatGPT")
        #expect(VocabularyMatcher.correct("用 Sense Voice 识别", terms: terms) == "用 SenseVoice 识别")
    }

    @Test func fixesSmallTyposInLongWords() {
        #expect(VocabularyMatcher.correct("部署到 kubernetis 集群", terms: ["Kubernetes"]) == "部署到 Kubernetes 集群")
        #expect(VocabularyMatcher.correct("ask cloud code to fix it", terms: ["Claude Code"]) == "ask Claude Code to fix it")
    }

    @Test func leavesOrdinaryWordsAlone() {
        // 短词不做模糊匹配
        #expect(VocabularyMatcher.correct("the nation", terms: ["Notion"]) == "the nation")
        // 复数不算拼错
        #expect(VocabularyMatcher.correct("two anthropics", terms: ["Anthropic"]) == "two anthropics")
        #expect(VocabularyMatcher.correct("SenseVoice 已经对了", terms: ["SenseVoice"]) == "SenseVoice 已经对了")
    }

    @Test func leavesURLsAndEmailsAlone() {
        let terms = ["GitHub"]
        #expect(VocabularyMatcher.correct("打开 github.com/abc", terms: terms) == "打开 github.com/abc")
        #expect(VocabularyMatcher.correct("发到 me@github.io", terms: terms) == "发到 me@github.io")
        #expect(VocabularyMatcher.correct("用 github。", terms: terms) == "用 GitHub。")
    }

    @Test func fixesChineseHomophones() {
        #expect(VocabularyMatcher.correct("明天找张三峰确认", terms: ["张三丰"]) == "明天找张三丰确认")
        // 两个字的词同音太多，不处理
        #expect(VocabularyMatcher.correct("开始实施", terms: ["史诗"]) == "开始实施")
        // 读音不同不改
        #expect(VocabularyMatcher.correct("找张小明", terms: ["张三丰"]) == "找张小明")
    }

    @Test func pipelineAppliesMatcherAfterReplacements() {
        var config = AppConfig()
        config.replacements = ["克劳德": "Claude"]
        config.vocabulary = ["GitHub"]
        #expect(TextPipeline.prepare("克劳德 和 github", config: config) == "Claude 和 GitHub")
    }
}

@Suite struct IncrementalChunkTests {
    @Test func finishedChunksMatchWholeRecording() {
        let rate = 100
        // 60 秒的"音频"：每 7 秒有一段安静
        let samples: [Float] = (0..<(60 * rate)).map { i in (i / rate) % 7 == 6 ? 0 : 0.5 }
        let whole = AudioMath.chunkRanges(samples, sampleRate: rate, maxSeconds: 20)
        let partial = AudioMath.finishedChunks(Array(samples.prefix(45 * rate)), sampleRate: rate, maxSeconds: 20)
        #expect(!partial.isEmpty)
        #expect(Array(whole.prefix(partial.count)) == partial)
    }

    @Test func shortRecordingHasNoFinishedChunk() {
        #expect(AudioMath.finishedChunks([Float](repeating: 0.3, count: 1000), sampleRate: 100, maxSeconds: 20).isEmpty)
    }
}

@Suite struct ExternalToggleTests {
    @Test func toggleStartsAndStopsHandsFree() {
        var sm = HotkeyStateMachine()
        #expect(sm.handle(.externalToggle) == [.startRecording])
        #expect(sm.state == .handsFree)
        // 打字不会取消
        #expect(sm.handle(.keyDown) == [])
        #expect(sm.handle(.externalToggle) == [.finishRecording])
        #expect(sm.state == .idle)
    }

    @Test func escapeCancelsExternalRecording() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.externalToggle)
        #expect(sm.handle(.escapeDown) == [.cancelRecording])
        #expect(sm.state == .idle)
    }
}

@Suite struct ExternalCommandTests {
    @Test func parsesCommands() {
        #expect(ExternalCommand(url: URL(string: "tidytalk://toggle")!) == .toggle)
        #expect(ExternalCommand(url: URL(string: "TIDYTALK://Start")!) == .start)
        #expect(ExternalCommand(url: URL(string: "tidytalk://stop")!) == .stop)
        #expect(ExternalCommand(url: URL(string: "tidytalk://cancel")!) == .cancel)
        #expect(ExternalCommand(url: URL(string: "tidytalk://captions")!) == .captions(.toggle))
        #expect(ExternalCommand(url: URL(string: "tidytalk://captions/start")!) == .captions(.start))
        #expect(ExternalCommand(url: URL(string: "tidytalk:toggle")!) == .toggle)
    }

    @Test func rejectsUnknown() {
        #expect(ExternalCommand(url: URL(string: "tidytalk://delete")!) == nil)
        #expect(ExternalCommand(url: URL(string: "https://toggle")!) == nil)
        #expect(ExternalCommand(url: URL(string: "tidytalk://captions/pause")!) == nil)
    }
}
