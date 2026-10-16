import Foundation

/// 常用 AI 接口的预设：填好接口地址、模型名和超时，API Key 保持不变。
public struct AIPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    /// 建议的模型名；为空时需要用户自己填写（例如 LM Studio 里已加载的模型）。
    public let model: String
    public let timeout: Double

    public static let all: [AIPreset] = [
        AIPreset(id: "deepseek", name: "DeepSeek",
                 baseURL: AIConfig.default.baseURL, model: AIConfig.default.model, timeout: AIConfig.default.timeout),
        // 本机模型首次加载、生成都比云端慢，超时放宽到 60 秒
        AIPreset(id: "ollama", name: "Ollama",
                 baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b", timeout: 60),
        AIPreset(id: "lmstudio", name: "LM Studio",
                 baseURL: "http://localhost:1234/v1", model: "", timeout: 60),
    ]

    public func applied(to config: AIConfig) -> AIConfig {
        var config = config
        config.baseURL = baseURL
        config.model = model
        config.timeout = timeout
        return config
    }
}

/// 设置界面里给用户选的三类 AI 服务。
public enum AIProvider: String, CaseIterable, Sendable {
    case ollama, lmStudio, cloud

    /// 切换到这一类时填入的预设；云端默认用 DeepSeek，用户可以再改成其他兼容接口。
    public var preset: AIPreset {
        let id = switch self {
        case .ollama: "ollama"
        case .lmStudio: "lmstudio"
        case .cloud: "deepseek"
        }
        return AIPreset.all.first { $0.id == id }!
    }

    /// 根据接口地址判断当前属于哪一类：本机的 11434 端口是 Ollama，1234 是 LM Studio，
    /// 不在本机的都算云端。本机的其他端口（例如自己跑的 llama.cpp）不属于任何一类，返回 nil。
    public static func detect(_ config: AIConfig) -> AIProvider? {
        guard config.isLocal else { return .cloud }
        switch config.chatCompletionsURL?.port {
        case 11434: return .ollama
        case 1234: return .lmStudio
        default: return nil
        }
    }
}
