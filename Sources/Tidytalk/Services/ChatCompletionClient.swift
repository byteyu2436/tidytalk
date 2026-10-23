import Foundation
import os
import TidytalkCore

/// OpenAI 兼容的 Chat Completions 接口，用于整理识别文本。
///
/// 默认配置指向 DeepSeek，也可以换成 OpenAI 或任何兼容该协议的服务（包括本地模型服务）。
struct ChatCompletionClient: Sendable {
    enum ClientError: LocalizedError {
        case notConfigured
        case unauthorized
        case http(Int, String?)
        case invalidResponse
        case truncated

        var errorDescription: String? {
            switch self {
            case .notConfigured: String(localized: "接口地址、API Key 或模型未填写")
            case .unauthorized: String(localized: "API Key 无效或已失效")
            case .http(let code, let message):
                message.map { String(localized: "接口返回错误 \(code)：\($0)") } ?? String(localized: "接口返回错误 \(code)")
            case .invalidResponse: String(localized: "AI 服务返回了无法识别的内容")
            case .truncated: String(localized: "AI 服务的回复不完整")
            }
        }
    }

    let config: AIConfig

    /// 不接受"关闭思考"字段的接口（地址 + 模型），记住后直接发普通请求，不再白白失败一次。
    private static let reasoningRejected = OSAllocatedUnfairLock(initialState: Set<String>())

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 返回模型原始输出，调用方负责用 `TranscriptCleanup.validate` 校验。
    func cleanup(_ transcript: String, style: CleanupStyle = .standard, vocabulary: [String] = [],
                 language: OutputLanguage = .original, level: CleanupLevel = .standard,
                 rules: [String] = []) async throws -> String {
        let messages = TranscriptCleanup.messages(for: transcript, style: style, vocabulary: vocabulary,
                                                  language: language, level: level, rules: rules)
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 按语音说出的要求改写选中的文字，返回模型原始输出，调用方用 `RewritePrompt.validate` 校验。
    func rewrite(selection: String, instruction: String, vocabulary: [String] = [],
                 rules: [String] = []) async throws -> String {
        let messages = RewritePrompt.messages(selection: selection, instruction: instruction,
                                              vocabulary: vocabulary, rules: rules)
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 翻译一句字幕，返回模型原始输出，调用方用 `CaptionTranslation.validate` 校验。
    func translateCaption(_ sentence: String, context: [String], language: OutputLanguage,
                          vocabulary: [String] = [], partial: Bool = false) async throws -> String {
        let messages = CaptionTranslation.messages(for: sentence, context: context, language: language,
                                                   vocabulary: vocabulary, partial: partial)
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 发一条最短的请求，同时验证地址、Key 和模型名。
    func testConnection() async throws {
        _ = try await complete([.init(role: "user", content: "回复 OK")])
    }

    private func complete(_ messages: [ChatRequest.Message]) async throws -> String {
        if config.service == .apple {
            return try await AppleIntelligence.complete(messages.map { ($0.role, $0.content) }, timeout: config.timeout)
        }
        guard config.isConfigured, let url = config.chatCompletionsURL else { throw ClientError.notConfigured }

        let model = config.model.trimmingCharacters(in: .whitespaces)
        let endpoint = url.absoluteString + "|" + model
        // 整理口语不需要思考：推理模型思考会慢很多，还会把思考过程混进回答里
        let switchOff = !Self.reasoningRejected.withLock { $0.contains(endpoint) }
        do {
            return try await send(messages, to: url, model: model, disableReasoning: switchOff)
        } catch ClientError.http(let code, _) where switchOff && (code == 400 || code == 422) {
            // 有的接口不认识这些字段，去掉后重试一次；成功了就记住
            let content = try await send(messages, to: url, model: model, disableReasoning: false)
            Self.reasoningRejected.withLock { _ = $0.insert(endpoint) }
            return content
        }
    }

    private func send(_ messages: [ChatRequest.Message], to url: URL, model: String,
                      disableReasoning: Bool) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        // 本机模型服务可以不填 Key，这时不发送认证信息
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = ChatRequest(model: model, messages: messages, temperature: config.temperature, stream: false)
        if disableReasoning {
            switch ModelOutput.reasoningSwitch(forBaseURL: config.baseURL) {
            case .effortNone: body.reasoning_effort = "none"
            case .openRouter: body.reasoning = .init(effort: "none", exclude: true)
            case .deepSeek: body.thinking = .init(type: "disabled")
            }
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClientError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw ClientError.http(http.statusCode, message)
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = decoded.choices.first, let content = choice.message.content
        else { throw ClientError.invalidResponse }
        // 回复因为长度上限被截断时，粘贴出去的会是半句话，按失败处理（调用方会粘贴原文）
        if choice.finish_reason == "length" { throw ClientError.truncated }
        guard let answer = ModelOutput.stripReasoning(content) else { throw ClientError.truncated }
        return answer
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Reasoning: Encodable {
        let effort: String
        let exclude: Bool
    }

    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    /// 为 nil 时不编码该字段。
    let temperature: Double?
    let stream: Bool
    // 关闭思考的字段，每次最多带一种（见 ModelOutput.ReasoningSwitch），为 nil 时不编码
    var reasoning_effort: String?
    var reasoning: Reasoning?
    var thinking: Thinking?
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finish_reason: String?
    }

    let choices: [Choice]
}

private struct ErrorResponse: Decodable {
    struct Body: Decodable { let message: String? }
    let error: Body
}
