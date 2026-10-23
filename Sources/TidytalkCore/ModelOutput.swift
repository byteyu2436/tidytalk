import Foundation

/// AI 服务返回内容的通用处理：去掉推理模型的"思考过程"，以及决定怎样请求关闭思考。
public enum ModelOutput {
    /// 去掉 `<think>…</think>` 这类思考过程和零宽字符，返回真正的回答。
    ///
    /// Ollama 里的 Qwen3、DeepSeek-R1 等推理模型会在回答前输出一段思考过程；
    /// 思考没写完就被截断（只有开头标签）时返回 nil，调用方应当按失败处理。
    public static func stripReasoning(_ content: String) -> String? {
        var text = content.replacingOccurrences(of: "[\\u200B\\u200C\\u200D\\u2060\\uFEFF]", with: "",
                                                options: .regularExpression)
        let blocks = try! NSRegularExpression(pattern: "<(think|thinking|reasoning)>[\\s\\S]*?</\\1>",
                                              options: [.caseInsensitive])
        text = blocks.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^<(think|thinking|reasoning)>", options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return trimmed
    }

    /// 请求时用来关闭思考的字段。各家服务的写法不同，每次只带一种。
    public enum ReasoningSwitch: Equatable, Sendable {
        /// 通用写法 `"reasoning_effort": "none"`：OpenAI、Ollama、LM Studio 等。
        case effortNone
        /// OpenRouter：`"reasoning": {"effort": "none", "exclude": true}`。
        case openRouter
        /// DeepSeek：`"thinking": {"type": "disabled"}`，它不接受 reasoning_effort 为 none。
        case deepSeek
    }

    public static func reasoningSwitch(forBaseURL baseURL: String) -> ReasoningSwitch {
        let url = baseURL.lowercased()
        if url.contains("api.deepseek.com") { return .deepSeek }
        if url.contains("openrouter.ai") { return .openRouter }
        return .effortNone
    }
}
