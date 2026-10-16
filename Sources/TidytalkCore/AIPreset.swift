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
        AIPreset(id: "ollama", name: String(localized: "Ollama（本机）"),
                 baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b", timeout: 60),
        AIPreset(id: "lmstudio", name: String(localized: "LM Studio（本机）"),
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
