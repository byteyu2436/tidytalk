import Foundation

/// AI 服务的种类。
public enum AIService: String, Sendable {
    /// OpenAI 兼容的接口：Ollama、LM Studio、DeepSeek、OpenAI 等。
    case openAICompatible = "openai"
    /// 系统自带的 Apple 智能（Foundation Models），在这台 Mac 上运行。
    case apple
}

/// 文本整理使用的 AI 服务配置。
public struct AIConfig: Equatable, Sendable {
    /// 例如 https://api.deepseek.com/v1、https://api.openai.com/v1
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// 为 nil 时不发送，适用于不允许修改 temperature 的模型。
    public var temperature: Double?
    /// 请求超时（秒），超时后直接粘贴原文。
    public var timeout: Double
    /// 使用哪一种服务：OpenAI 兼容接口，或者系统自带的 Apple 智能（这时接口地址等字段不用）。
    public var service: AIService

    public init(baseURL: String, apiKey: String, model: String, temperature: Double?, timeout: Double,
                service: AIService = .openAICompatible) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
        self.service = service
    }

    public static let `default` = AIConfig(
        baseURL: "https://api.deepseek.com/v1",
        apiKey: "",
        model: "deepseek-chat",
        temperature: 0,
        timeout: 12
    )

    /// 实际使用的超时：不流式返回时，服务端整理完才开始回传，长段口述需要更久。
    /// 按输入长度放大，五六百字约 34 秒；用户设置得更长时以用户为准。
    public func timeout(forInputLength length: Int) -> Double {
        max(timeout, 10 + Double(length) / 25)
    }

    /// `{base_url}/chat/completions`
    public var chatCompletionsURL: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }

    /// 接口在本机（Ollama、LM Studio 等）或者使用 Apple 智能，文字不会离开这台 Mac，也不需要 API Key。
    public var isLocal: Bool {
        if service == .apple { return true }
        guard let host = chatCompletionsURL?.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }

    /// Apple 智能不需要填写任何东西；这台 Mac 能不能用，调用时再检查。
    public var isConfigured: Bool {
        if service == .apple { return true }
        return chatCompletionsURL != nil
            && (isLocal || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 用户配置，保存在 `~/.tidytalk.json`：
///
/// ```json
/// {
///   "cleanup_enabled": true,
///   "ai": {
///     "base_url": "https://api.deepseek.com/v1",
///     "api_key": "sk-...",
///     "model": "deepseek-chat",
///     "temperature": 0,
///     "timeout": 12
///   },
///   "typography": true,
///   "vocabulary": ["Claude", "SenseVoice"],
///   "replacements": { "克劳德": "Claude" },
///   "style": "standard",
///   "output_language": "original",
///   "hotkey": "option_command",
///   "microphone": "",
///   "history": true,
///   "history_days": 30,
///   "hands_free": true,
///   "rewrite_hotkey": "right_option",
///   "sounds": true,
///   "cleanup_level": "standard",
///   "snippets": { "我的邮箱": "name@example.com" },
///   "custom_rules": ["金额一律用阿拉伯数字"],
///   "auto_update_check": true,
///   "live_preview": true,
///   "listen_source": "",
///   "caption_size": "medium",
///   "caption_auto_hide": true,
///   "caption_translate": false,
///   "caption_language": "zh-Hans",
///   "caption_style": "dark",
///   "caption_live_translate": true,
///   "speech_model": "sense_voice",
///   "learn_corrections": true,
///   "meeting_keep_recording": true,
///   "meeting_auto_summary": false,
///   "meeting_diarize": true,
///   "meeting_source": "",
///   "appearance": "system"
/// }
/// ```
public struct AppConfig: Equatable, Sendable {
    public var cleanupEnabled: Bool
    public var ai: AIConfig
    /// 中英文排版规范（加空格、统一标点），本地处理，不依赖 AI 整理。
    public var typography: Bool
    /// 个人词库，放进 AI 整理的提示里。
    public var vocabulary: [String]
    /// 固定替换表，错误写法 → 正确写法，本地处理。
    public var replacements: [String: String]
    /// 整理模式。
    public var style: CleanupStyle
    /// 输出语言，选了其他语言时整理后翻译。
    public var outputLanguage: OutputLanguage
    /// 按住说话的触发键。
    public var hotkey: HotkeyKey
    /// 录音使用的麦克风（Core Audio 设备 UID），空字符串表示跟随系统默认。
    public var microphone: String
    /// 是否把说话记录保存在这台 Mac 上（资料库里可以搜索）。关闭时只放在内存里，退出应用即清空。
    public var history: Bool
    /// 说话记录保留几天，超过的自动删除；0 表示一直保留。
    public var historyDays: Int
    /// 设置里可以选的保留天数（0 是一直保留）。
    public static let historyDayChoices = [7, 30, 90, 365, 0]
    /// 双击触发键进入免按住录音。
    public var handsFree: Bool
    /// 语音改写选中文字的触发键，nil 表示关闭。不能和 `hotkey` 相同。
    public var rewriteHotkey: HotkeyKey?
    /// 开始、结束录音时的提示音。
    public var sounds: Bool
    /// 整理强度。
    public var cleanupLevel: CleanupLevel
    /// 快捷短语：说出的短语 → 输出的内容。
    public var snippets: [String: String]
    /// 用户补充的整理规则，AI 整理和语音改写时遵守。
    public var customRules: [String]
    /// 启动时自动检查更新（需要构建时配置了更新地址）。
    public var autoUpdateCheck: Bool
    /// 说话时在指示器下方显示实时识别的文字（只是预览，最终结果仍在松开后生成）。
    public var livePreview: Bool
    /// 实时字幕收听的应用（bundle id），空字符串表示收听全部声音。
    public var listenSource: String
    /// 实时字幕的文字大小。
    public var captionSize: CaptionSize
    /// 一段时间没有声音后自动隐藏字幕。
    public var captionAutoHide: Bool
    /// 字幕下方显示译文（使用"配置 AI"里的服务）。
    public var captionTranslate: Bool
    /// 字幕翻译成的语言，不会是 `.original`。
    public var captionLanguage: OutputLanguage
    /// 字幕条的样式。
    public var captionStyle: CaptionStyle
    /// 字幕翻译时，正在说的这句也边听边翻译（会多调用几次 AI 服务）。
    public var captionLiveTranslate: Bool
    /// 语音识别模型。
    public var speechModel: SpeechModel
    /// 粘贴后发现用户改了某个词时，提示加入词库。
    public var learnCorrections: Bool
    /// 会议模式：会后保留录音（可以回听、重新分说话人）。关闭时处理完只留文字。
    public var meetingKeepRecording: Bool
    /// 会议模式：会议结束、处理完后自动生成 AI 总结。
    public var meetingAutoSummary: Bool
    /// 会议模式：会后用说话人模型把对方分成几个人（需要下载说话人模型）。关闭时只分“我”和“对方”。
    public var meetingDiarize: Bool
    /// 会议模式收听的应用（bundle id），空字符串表示电脑的全部声音。
    public var meetingSource: String
    /// 界面的深浅色。
    public var appearance: AppAppearance

    public init(cleanupEnabled: Bool = true, ai: AIConfig = .default, typography: Bool = true,
                vocabulary: [String] = [], replacements: [String: String] = [:],
                style: CleanupStyle = .standard, outputLanguage: OutputLanguage = .original,
                hotkey: HotkeyKey = .optionCommand, microphone: String = "", history: Bool = true,
                historyDays: Int = 30, handsFree: Bool = true, rewriteHotkey: HotkeyKey? = .rightOption, sounds: Bool = true,
                cleanupLevel: CleanupLevel = .standard, snippets: [String: String] = [:],
                customRules: [String] = [], autoUpdateCheck: Bool = true, livePreview: Bool = true,
                listenSource: String = "", captionSize: CaptionSize = .medium, captionAutoHide: Bool = true,
                captionTranslate: Bool = false, captionLanguage: OutputLanguage = .captionDefault(),
                captionStyle: CaptionStyle = .dark, captionLiveTranslate: Bool = true,
                speechModel: SpeechModel = .senseVoice,
                learnCorrections: Bool = true, meetingKeepRecording: Bool = true, meetingAutoSummary: Bool = false,
                meetingDiarize: Bool = true, meetingSource: String = "", appearance: AppAppearance = .system) {
        self.cleanupEnabled = cleanupEnabled
        self.ai = ai
        self.typography = typography
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.style = style
        self.outputLanguage = outputLanguage
        self.hotkey = hotkey
        self.microphone = microphone
        self.history = history
        self.historyDays = Self.historyDayChoices.contains(historyDays) ? historyDays : 30
        self.handsFree = handsFree
        // 两个触发键相同时不在这里改写成关闭：改回不同的触发键后应该恢复。实际使用看 activeRewriteHotkey
        self.rewriteHotkey = rewriteHotkey
        self.sounds = sounds
        self.cleanupLevel = cleanupLevel
        self.snippets = snippets
        self.customRules = customRules
        self.autoUpdateCheck = autoUpdateCheck
        self.livePreview = livePreview
        self.listenSource = listenSource
        self.captionSize = captionSize
        self.captionAutoHide = captionAutoHide
        self.captionTranslate = captionTranslate
        self.captionLanguage = captionLanguage.isTranslation ? captionLanguage : .captionDefault()
        self.captionStyle = captionStyle
        self.captionLiveTranslate = captionLiveTranslate
        self.speechModel = speechModel
        self.learnCorrections = learnCorrections
        self.meetingKeepRecording = meetingKeepRecording
        self.meetingAutoSummary = meetingAutoSummary
        self.meetingDiarize = meetingDiarize
        self.meetingSource = meetingSource
        self.appearance = appearance
    }

    /// 实际生效的语音改写触发键：和说话的触发键相同时视为关闭。
    public var activeRewriteHotkey: HotkeyKey? {
        rewriteHotkey == hotkey ? nil : rewriteHotkey
    }

    public enum ParseError: LocalizedError {
        case notAnObject

        public var errorDescription: String? { String(localized: "配置文件不是有效的 JSON 对象") }
    }

    private enum Key {
        static let cleanupEnabled = "cleanup_enabled"
        static let ai = "ai"
        static let baseURL = "base_url"
        static let apiKey = "api_key"
        static let model = "model"
        static let temperature = "temperature"
        static let timeout = "timeout"
        static let typography = "typography"
        static let vocabulary = "vocabulary"
        static let replacements = "replacements"
        static let style = "style"
        static let outputLanguage = "output_language"
        static let hotkey = "hotkey"
        static let microphone = "microphone"
        static let history = "history"
        static let historyDays = "history_days"
        static let handsFree = "hands_free"
        static let rewriteHotkey = "rewrite_hotkey"
        static let sounds = "sounds"
        static let cleanupLevel = "cleanup_level"
        static let snippets = "snippets"
        static let customRules = "custom_rules"
        static let autoUpdateCheck = "auto_update_check"
        static let livePreview = "live_preview"
        static let listenSource = "listen_source"
        static let captionSize = "caption_size"
        static let captionAutoHide = "caption_auto_hide"
        static let captionTranslate = "caption_translate"
        static let captionLanguage = "caption_language"
        static let captionStyle = "caption_style"
        static let captionLiveTranslate = "caption_live_translate"
        static let speechModel = "speech_model"
        static let learnCorrections = "learn_corrections"
        static let meetingKeepRecording = "meeting_keep_recording"
        static let meetingAutoSummary = "meeting_auto_summary"
        static let meetingDiarize = "meeting_diarize"
        static let meetingSource = "meeting_source"
        static let appearance = "appearance"
        static let service = "service"
        static let off = "off"
        /// 旧版本的按应用风格，已废弃，写回时删除
        static let legacyAppStyles = "app_styles"
    }

    /// 缺少的字段使用默认值。
    public static func decode(_ data: Data) throws -> AppConfig {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        let ai = root[Key.ai] as? [String: Any] ?? [:]
        let defaults = AIConfig.default

        let temperature: Double?
        if ai.keys.contains(Key.temperature) {
            temperature = (ai[Key.temperature] as? NSNumber)?.doubleValue
        } else {
            temperature = defaults.temperature
        }

        return AppConfig(
            cleanupEnabled: (root[Key.cleanupEnabled] as? Bool) ?? true,
            ai: AIConfig(
                baseURL: (ai[Key.baseURL] as? String) ?? defaults.baseURL,
                apiKey: (ai[Key.apiKey] as? String) ?? defaults.apiKey,
                model: (ai[Key.model] as? String) ?? defaults.model,
                temperature: temperature,
                timeout: (ai[Key.timeout] as? NSNumber)?.doubleValue ?? defaults.timeout,
                service: (ai[Key.service] as? String).flatMap(AIService.init(rawValue:)) ?? .openAICompatible
            ),
            typography: (root[Key.typography] as? Bool) ?? true,
            vocabulary: (root[Key.vocabulary] as? [Any])?.compactMap { $0 as? String } ?? [],
            replacements: (root[Key.replacements] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            // 无法识别的模式名使用标准模式
            style: (root[Key.style] as? String).flatMap(CleanupStyle.init(rawValue:)) ?? .standard,
            // 无法识别的语言按"与原文相同"处理
            outputLanguage: (root[Key.outputLanguage] as? String).flatMap(OutputLanguage.init(rawValue:)) ?? .original,
            hotkey: (root[Key.hotkey] as? String).flatMap(HotkeyKey.init(rawValue:)) ?? .optionCommand,
            microphone: (root[Key.microphone] as? String) ?? "",
            history: (root[Key.history] as? Bool) ?? true,
            historyDays: (root[Key.historyDays] as? Int) ?? 30,
            handsFree: (root[Key.handsFree] as? Bool) ?? true,
            rewriteHotkey: {
                guard let raw = root[Key.rewriteHotkey] as? String else { return .rightOption }
                return raw == Key.off ? nil : HotkeyKey(rawValue: raw) ?? .rightOption
            }(),
            sounds: (root[Key.sounds] as? Bool) ?? true,
            cleanupLevel: (root[Key.cleanupLevel] as? String).flatMap(CleanupLevel.init(rawValue:)) ?? .standard,
            snippets: (root[Key.snippets] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            customRules: (root[Key.customRules] as? [Any])?.compactMap { $0 as? String } ?? [],
            autoUpdateCheck: (root[Key.autoUpdateCheck] as? Bool) ?? true,
            livePreview: (root[Key.livePreview] as? Bool) ?? true,
            listenSource: (root[Key.listenSource] as? String) ?? "",
            captionSize: (root[Key.captionSize] as? String).flatMap(CaptionSize.init(rawValue:)) ?? .medium,
            captionAutoHide: (root[Key.captionAutoHide] as? Bool) ?? true,
            captionTranslate: (root[Key.captionTranslate] as? Bool) ?? false,
            captionLanguage: (root[Key.captionLanguage] as? String).flatMap(OutputLanguage.init(rawValue:)) ?? .captionDefault(),
            captionStyle: (root[Key.captionStyle] as? String).flatMap(CaptionStyle.init(rawValue:)) ?? .dark,
            captionLiveTranslate: (root[Key.captionLiveTranslate] as? Bool) ?? true,
            speechModel: (root[Key.speechModel] as? String).flatMap(SpeechModel.init(rawValue:)) ?? .senseVoice,
            learnCorrections: (root[Key.learnCorrections] as? Bool) ?? true,
            meetingKeepRecording: (root[Key.meetingKeepRecording] as? Bool) ?? true,
            meetingAutoSummary: (root[Key.meetingAutoSummary] as? Bool) ?? false,
            meetingDiarize: (root[Key.meetingDiarize] as? Bool) ?? true,
            meetingSource: (root[Key.meetingSource] as? String) ?? "",
            appearance: (root[Key.appearance] as? String).flatMap(AppAppearance.init(rawValue:)) ?? .system
        )
    }

    /// 写回时保留文件里其他未知字段。
    public func encode(merging existing: Data? = nil) throws -> Data {
        var root = existing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var ai = root[Key.ai] as? [String: Any] ?? [:]

        root[Key.cleanupEnabled] = cleanupEnabled
        ai[Key.baseURL] = self.ai.baseURL
        ai[Key.apiKey] = self.ai.apiKey
        ai[Key.model] = self.ai.model
        ai[Key.temperature] = self.ai.temperature.map { $0 as Any } ?? NSNull()
        ai[Key.timeout] = self.ai.timeout
        ai[Key.service] = self.ai.service.rawValue
        root[Key.ai] = ai
        root[Key.typography] = typography
        root[Key.vocabulary] = vocabulary
        root[Key.replacements] = replacements
        root[Key.style] = style.rawValue
        root[Key.outputLanguage] = outputLanguage.rawValue
        root[Key.hotkey] = hotkey.rawValue
        root[Key.microphone] = microphone
        root[Key.history] = history
        root[Key.historyDays] = historyDays
        root[Key.handsFree] = handsFree
        root[Key.rewriteHotkey] = rewriteHotkey?.rawValue ?? Key.off
        root[Key.sounds] = sounds
        root[Key.cleanupLevel] = cleanupLevel.rawValue
        root[Key.snippets] = snippets
        root[Key.customRules] = customRules
        root[Key.autoUpdateCheck] = autoUpdateCheck
        root[Key.livePreview] = livePreview
        root[Key.listenSource] = listenSource
        root[Key.captionSize] = captionSize.rawValue
        root[Key.captionAutoHide] = captionAutoHide
        root[Key.captionTranslate] = captionTranslate
        root[Key.captionLanguage] = captionLanguage.rawValue
        root[Key.captionStyle] = captionStyle.rawValue
        root[Key.captionLiveTranslate] = captionLiveTranslate
        root[Key.speechModel] = speechModel.rawValue
        root[Key.learnCorrections] = learnCorrections
        root[Key.meetingKeepRecording] = meetingKeepRecording
        root[Key.meetingAutoSummary] = meetingAutoSummary
        root[Key.meetingDiarize] = meetingDiarize
        root[Key.meetingSource] = meetingSource
        root[Key.appearance] = appearance.rawValue
        root[Key.legacyAppStyles] = nil

        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
