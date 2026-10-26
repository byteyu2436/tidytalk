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
        // 总时长上限放宽，具体每个请求的超时见 AIConfig.timeout(forInputLength:)
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 会议总结：一次要读几万字、写上千字，本机模型可能要好几分钟，单独放宽到 15 分钟。
    private static let longSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 一次请求的方式：普通请求（整理、改写、翻译）按输入长度算超时，回复被截断按失败处理；
    /// 会议总结用更长的超时，回复被截断时保留已经写出的部分。
    private struct Options {
        var timeout: Double?
        var long = false
    }

    /// 返回模型原始输出，调用方负责用 `TranscriptCleanup.validate` 校验。
    func cleanup(_ transcript: String, style: CleanupStyle = .standard, vocabulary: [String] = [],
                 language: OutputLanguage = .original, level: CleanupLevel = .standard,
                 rules: [String] = []) async throws -> String {
        let messages = TranscriptCleanup.messages(for: transcript, style: style, vocabulary: trimmed(vocabulary),
                                                  language: language, level: level, rules: trimmed(rules: rules))
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 按语音说出的要求改写选中的文字，返回模型原始输出，调用方用 `RewritePrompt.validate` 校验。
    func rewrite(selection: String, instruction: String, vocabulary: [String] = [],
                 rules: [String] = []) async throws -> String {
        let messages = RewritePrompt.messages(selection: selection, instruction: instruction,
                                              vocabulary: trimmed(vocabulary), rules: trimmed(rules: rules))
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// 翻译一句字幕，返回模型原始输出，调用方用 `CaptionTranslation.validate` 校验。
    func translateCaption(_ sentence: String, context: [String], language: OutputLanguage,
                          vocabulary: [String] = [], partial: Bool = false) async throws -> String {
        let messages = CaptionTranslation.messages(for: sentence, context: context, language: language,
                                                   vocabulary: trimmed(vocabulary), partial: partial)
        return try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) })
    }

    /// Apple 智能的端侧模型上下文窗口小（约 4K token），词库和规则太多会直接失败，只带最常用的一部分。
    private func trimmed(_ vocabulary: [String]) -> [String] {
        config.service == .apple ? Array(Vocabulary.normalize(vocabulary).prefix(30)) : vocabulary
    }

    private func trimmed(rules: [String]) -> [String] {
        config.service == .apple ? Array(rules.prefix(8)) : rules
    }

    /// 发一条最短的请求，同时验证地址、Key 和模型名。
    func testConnection() async throws {
        _ = try await complete([.init(role: "user", content: "回复 OK")])
    }

    private func complete(_ messages: [ChatRequest.Message]) async throws -> String {
        try await complete(messages, options: Options()).text
    }

    private func complete(_ messages: [ChatRequest.Message], options: Options) async throws -> (text: String, truncated: Bool) {
        let timeout = options.timeout ?? config.timeout(forInputLength: messages.last?.content.count ?? 0)
        if config.service == .apple {
            return (try await AppleIntelligence.complete(messages.map { ($0.role, $0.content) }, timeout: timeout), false)
        }
        guard config.isConfigured, let url = config.chatCompletionsURL else { throw ClientError.notConfigured }

        let model = config.model.trimmingCharacters(in: .whitespaces)
        let endpoint = url.absoluteString + "|" + model
        // 整理口语不需要思考：推理模型思考会慢很多，还会把思考过程混进回答里
        let switchOff = !Self.reasoningRejected.withLock { $0.contains(endpoint) }
        do {
            return try await send(messages, to: url, model: model, disableReasoning: switchOff, timeout: timeout,
                                  long: options.long)
        } catch ClientError.http(let code, let message)
                    where switchOff && (code == 400 || code == 422) && ModelOutput.rejectedReasoningFields(message: message) {
            // 有的接口不认识这些字段，去掉后重试一次；成功了就记住
            let content = try await send(messages, to: url, model: model, disableReasoning: false, timeout: timeout,
                                         long: options.long)
            Self.reasoningRejected.withLock { _ = $0.insert(endpoint) }
            return content
        }
    }

    private func send(_ messages: [ChatRequest.Message], to url: URL, model: String,
                      disableReasoning: Bool, timeout: Double, long: Bool) async throws -> (text: String, truncated: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
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

        let (data, response) = try await (long ? Self.longSession : Self.session).data(for: request)
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
        // 回复因为长度上限被截断时，粘贴出去的会是半句话，按失败处理（调用方会粘贴原文）；
        // 会议总结保留已经写出的部分，标记为不完整
        let truncated = choice.finish_reason == "length"
        if truncated, !long { throw ClientError.truncated }
        guard let answer = ModelOutput.stripReasoning(content) else { throw ClientError.truncated }
        return (answer, truncated)
    }
}

// MARK: - 会议总结

extension ChatCompletionClient {
    enum SummaryError: LocalizedError {
        case empty

        var errorDescription: String? { String(localized: "这场会议还没有文字，无法总结") }
    }

    /// 总结一场会议，返回 Markdown 和是否有部分内容没写完。长会议先分块整理成笔记，再合成一份总结。
    /// - Parameter onProgress: 0...1，在调用方的 actor 上回调。
    func summarizeMeeting(_ meeting: Meeting,
                          onProgress: @escaping (Double) -> Void = { _ in }) async throws -> (markdown: String, partial: Bool) {
        let lines = MeetingSummaryPrompt.transcriptLines(meeting)
        guard !lines.isEmpty else { throw SummaryError.empty }
        var limit = config.service == .apple ? MeetingSummaryPrompt.ChunkSize.appleIntelligence
            : MeetingSummaryPrompt.ChunkSize.standard
        #if DEBUG || TIDYTALK_DEV_TOOLS
        // 开发用：TIDYTALK_SUMMARY_CHUNK=300 用很小的块测试长会议的分块和合并
        if let value = ProcessInfo.processInfo.environment["TIDYTALK_SUMMARY_CHUNK"], let size = Int(value) { limit = size }
        #endif
        let chunks = MeetingSummaryPrompt.chunks(lines, limit: limit)
        var partial = false

        if chunks.count == 1 {
            let (text, cut) = try await summaryRequest(MeetingSummaryPrompt.messages(transcript: chunks[0]))
            return (text, cut)
        }

        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let (chunkNotes, cut) = try await notesFor(chunk, index: index + 1, total: chunks.count)
            notes += chunkNotes
            partial = partial || cut
            onProgress(Double(index + 1) / Double(chunks.count + 1))
        }
        // 各段笔记加起来还是太长：先分组合并，直到一次放得下
        var round = notes
        while true {
            try Task.checkCancellation()
            let groups = MeetingSummaryPrompt.mergeRounds(round, limit: limit)
            // 只剩一组，或者每段笔记本身就超过上限、分组也减少不了：直接全部一起合并
            if groups.count == 1 || groups.count == round.count {
                let (text, cut) = try await summaryRequest(MeetingSummaryPrompt.mergeMessages(notes: round))
                onProgress(1)
                return (text, partial || cut)
            }
            var merged: [String] = []
            for group in groups {
                let (text, cut) = try await summaryRequest(MeetingSummaryPrompt.mergeMessages(notes: group))
                merged.append(text)
                partial = partial || cut
            }
            round = merged
        }
    }

    /// 一块会议记录整理成笔记。Apple 智能说内容太长时，切成两半各自整理。
    private func notesFor(_ chunk: String, index: Int, total: Int) async throws -> ([String], Bool) {
        do {
            let (text, cut) = try await summaryRequest(MeetingSummaryPrompt.partialMessages(chunk: chunk, index: index,
                                                                                          total: total))
            return ([text], cut)
        } catch AppleIntelligence.Failure.tooLong where chunk.count > 200 {
            let lines = chunk.components(separatedBy: "\n")
            let half = max(1, lines.count / 2)
            let halves = lines.count > 1 ? [lines[..<half], lines[half...]].map { $0.joined(separator: "\n") }
                : [String(chunk.prefix(chunk.count / 2)), String(chunk.dropFirst(chunk.count / 2))]
            var notes: [String] = []
            var partial = false
            for part in halves {
                let (more, cut) = try await notesFor(part, index: index, total: total)
                notes += more
                partial = partial || cut
            }
            return (notes, partial)
        }
    }

    private func summaryRequest(_ messages: [TranscriptCleanup.Message]) async throws -> (String, Bool) {
        let length = messages.last?.content.count ?? 0
        // 读得多、写得也多：至少 60 秒，每 30 个字再加 1 秒
        let timeout = max(config.timeout, 60 + Double(length) / 30)
        let (text, cut) = try await complete(messages.map { .init(role: $0.role.rawValue, content: $0.content) },
                                             options: Options(timeout: timeout, long: true))
        guard let valid = MeetingSummaryPrompt.validate(text) else { throw ClientError.invalidResponse }
        return (valid, cut)
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
