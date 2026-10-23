import Foundation
import FoundationModels

/// 系统自带的 Apple 智能（Foundation Models）：在这台 Mac 上运行的大模型，文字不离开电脑。
///
/// 需要支持 Apple 智能的 Mac，并且在"系统设置 › Apple 智能与 Siri"里打开。
enum AppleIntelligence {
    enum Failure: LocalizedError {
        case unavailable(String)
        case timedOut
        case tooLong
        case refused

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .timedOut: String(localized: "Apple 智能响应超时")
            case .tooLong: String(localized: "内容太长，Apple 智能处理不了")
            case .refused: String(localized: "Apple 智能拒绝处理这段内容")
            }
        }
    }

    /// 不能使用时的原因；能用时为 nil。
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            String(localized: "这台 Mac 不支持 Apple 智能")
        case .unavailable(.appleIntelligenceNotEnabled):
            String(localized: "请先在系统设置里打开 Apple 智能")
        case .unavailable(.modelNotReady):
            String(localized: "Apple 智能还没准备好，请稍后再试")
        case .unavailable:
            String(localized: "Apple 智能暂时不可用")
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// 按对话格式调用：system 作为指令，中间的示例对话写进指令里，最后一条用户消息作为输入。
    static func complete(_ messages: [(role: String, content: String)], timeout: Double) async throws -> String {
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
        var instructions = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != "system" }
        guard let prompt = turns.last(where: { $0.role == "user" })?.content else { return "" }
        let examples = zip(turns.dropLast(), turns.dropLast().dropFirst())
            .filter { $0.0.role == "user" && $0.1.role == "assistant" }
        if !examples.isEmpty {
            instructions += "\n\n" + examples.map { "输入：\($0.0.content)\n输出：\($0.1.content)" }
                .joined(separator: "\n\n")
        }

        let session = LanguageModelSession(instructions: instructions)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
                } catch let error as LanguageModelSession.GenerationError {
                    // 分开提示，用户才知道是内容太长还是被安全规则拦下
                    switch error {
                    case .exceededContextWindowSize: throw Failure.tooLong
                    case .guardrailViolation, .refusal: throw Failure.refused
                    default: throw error
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
