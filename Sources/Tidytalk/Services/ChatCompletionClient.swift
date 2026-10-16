import Foundation
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

        var errorDescription: String? {
            switch self {
            case .notConfigured: String(localized: "接口地址、API Key 或模型未填写")
            case .unauthorized: String(localized: "API Key 无效或已失效")
            case .http(let code, let message):
                message.map { String(localized: "接口返回错误 \(code)：\($0)") } ?? String(localized: "接口返回错误 \(code)")
            case .invalidResponse: String(localized: "AI 服务返回了无法识别的内容")
            }
        }
    }

    let config: AIConfig

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
                          vocabulary: [String] = []) async throws -> String {
        let messages = CaptionTranslation.messages(for: sentence, context: context, language: language,
                                                   vocabulary: vocabulary)
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 发一条最短的请求，同时验证地址、Key 和模型名。
    func testConnection() async throws {
        _ = try await complete([.init(role: "user", content: "回复 OK")])
    }

    private func complete(_ messages: [ChatRequest.Message]) async throws -> String {
        guard config.isConfigured, let url = config.chatCompletionsURL else { throw ClientError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        // 本机模型服务可以不填 Key，这时不发送认证信息
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: config.model.trimmingCharacters(in: .whitespaces),
            messages: messages,
            temperature: config.temperature,
            stream: false
        ))

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
              let content = decoded.choices.first?.message.content
        else { throw ClientError.invalidResponse }
        return content
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    /// 为 nil 时不编码该字段。
    let temperature: Double?
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }

    let choices: [Choice]
}

private struct ErrorResponse: Decodable {
    struct Body: Decodable { let message: String? }
    let error: Body
}
