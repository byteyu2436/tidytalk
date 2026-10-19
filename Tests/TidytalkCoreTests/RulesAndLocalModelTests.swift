import Foundation
import Testing
@testable import TidytalkCore

@Suite struct CustomRulesTests {
    @Test func normalizeTrimsAndLimits() {
        let rules = [" 金额用阿拉伯数字 ", "", "金额用阿拉伯数字", String(repeating: "长", count: 300)]
            + (1...30).map { "规则\($0)" }
        let normalized = CustomRules.normalize(rules)
        #expect(normalized.first == "金额用阿拉伯数字")
        #expect(normalized.count == CustomRules.limit)
        #expect(normalized[1].count == CustomRules.maxLength)
    }

    @Test func rulesAppearInPrompts() {
        let rules = ["金额一律用阿拉伯数字", "产品名写作 Tidytalk"]
        let cleanup = TranscriptCleanup.systemPrompt(rules: rules)
        #expect(cleanup.contains("1. 金额一律用阿拉伯数字"))
        #expect(cleanup.contains("2. 产品名写作 Tidytalk"))
        #expect(TranscriptCleanup.systemPrompt(rules: []) == TranscriptCleanup.systemPrompt)
        let rewrite = RewritePrompt.messages(selection: "a", instruction: "b", rules: rules)
        #expect(rewrite[0].content.contains("产品名写作 Tidytalk"))
    }

    @Test func configRoundTrip() throws {
        let config = AppConfig(customRules: ["称呼统一用您"])
        #expect(try AppConfig.decode(config.encode()) == config)
        #expect(try AppConfig.decode(Data("{}".utf8)).customRules.isEmpty)
    }
}

@Suite struct LocalModelTests {
    @Test func localEndpointsNeedNoKey() {
        var ai = AIConfig.default
        ai.apiKey = ""
        #expect(!ai.isConfigured)
        ai.baseURL = "http://localhost:11434/v1"
        #expect(ai.isLocal && ai.isConfigured)
        ai.baseURL = "http://127.0.0.1:1234/v1"
        #expect(ai.isLocal)
        ai.baseURL = "https://api.openai.com/v1"
        #expect(!ai.isLocal && !ai.isConfigured)
    }

    @Test func presetsKeepKey() {
        var ai = AIConfig.default
        ai.apiKey = "sk-keep"
        let ollama = AIPreset.all.first { $0.id == "ollama" }!.applied(to: ai)
        #expect(ollama.apiKey == "sk-keep")
        #expect(ollama.isLocal && ollama.timeout == 60)
        let lmStudio = AIPreset.all.first { $0.id == "lmstudio" }!.applied(to: ai)
        #expect(lmStudio.model.isEmpty && !lmStudio.isConfigured)
        let deepseek = AIPreset.all.first { $0.id == "deepseek" }!.applied(to: ollama)
        #expect(deepseek.baseURL == AIConfig.default.baseURL && deepseek.apiKey == "sk-keep")
    }

    @Test func providerDetectionFollowsTheEndpoint() {
        var ai = AIConfig.default
        #expect(AIProvider.detect(ai) == .cloud)
        ai = AIProvider.ollama.applied(to: ai)
        #expect(AIProvider.detect(ai) == .ollama)
        ai = AIProvider.lmStudio.applied(to: ai)
        #expect(AIProvider.detect(ai) == .lmStudio)
        ai.baseURL = "http://127.0.0.1:8080/v1"
        #expect(AIProvider.detect(ai) == nil)
        ai.baseURL = "https://api.openai.com/v1"
        #expect(AIProvider.detect(ai) == .cloud)
        // 切回云端时恢复 DeepSeek 的默认地址和模型，API Key 保持不变
        ai.apiKey = "sk-test"
        let cloud = AIProvider.cloud.applied(to: AIProvider.ollama.applied(to: ai))
        #expect(cloud.baseURL == AIConfig.default.baseURL && cloud.apiKey == "sk-test")
    }
}
