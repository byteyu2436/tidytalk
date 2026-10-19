import Foundation
import Observation
import TidytalkCore

/// 全局可观察状态：指示器、菜单栏图标、设置界面都从这里读取。
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording
        case processing
        case message(String)
    }

    enum Readiness: Equatable {
        case ready
        case needsMicrophone
        case needsAccessibility
        case modelNotReady
    }

    var phase: Phase = .idle {
        didSet { if phase != .idle { visiblePhase = phase } }
    }
    /// 指示器显示的内容：淡出时保留最后的状态，避免胶囊先变空再消失。
    private(set) var visiblePhase: Phase = .idle
    /// 指示器上显示的处理方式（"整理"、"译成英文"这类文案或"改写"），只转文字时为 nil。
    var indicatorTag: String?
    /// 语音改写时在胶囊周围显示光点。
    var sparkles = false
    /// 说话时实时识别出的文字，显示在胶囊下方。
    var livePreview = ""
    /// 是否显示实时文字的胶囊。单独保存，避免每次文字更新都重新排版指示器。
    var showsLivePreview = false
    /// 最近的电平，最新的在末尾。
    private(set) var levels: [Float] = Array(repeating: 0, count: AppModel.levelHistory)

    /// 实时字幕：是否正在收听电脑的声音、是否暂停、显示的文字。
    var isListening = false
    var listeningPaused = false
    var captions = CaptionTranscript()

    var microphoneGranted = Permissions.microphone == .granted
    var accessibilityGranted = Permissions.accessibility

    /// 每个识别模型各自的下载状态。
    let modelManagers: [SpeechModel: ModelManager] = Dictionary(
        uniqueKeysWithValues: SpeechModel.allCases.map { ($0, ModelManager(model: $0)) })

    /// 当前选中的识别模型。
    var models: ModelManager { modelManagers[configStore.config.speechModel]! }

    /// 换用另一个识别模型。还没下载时先下载，下载完成后再切换，期间继续用原来的模型。
    func useSpeechModel(_ speechModel: SpeechModel) {
        guard let manager = modelManagers[speechModel] else { return }
        if manager.isReady {
            configStore.update { $0.speechModel = speechModel }
        } else {
            manager.useWhenReady = { [weak self] in self?.configStore.update { $0.speechModel = speechModel } }
            manager.download()
        }
    }

    /// `~/.tidytalk.json` 中的整理开关和 AI 接口配置。
    let configStore = ConfigStore()

    var cleanupEnabled: Bool {
        get { configStore.config.cleanupEnabled }
        set {
            var config = configStore.config
            config.cleanupEnabled = newValue
            configStore.save(config)
        }
    }

    var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// 最近的识别结果，最新的在前。只保存在内存中，退出应用即清空。
    private(set) var history: [HistoryEntry] = []
    static let historyLimit = 20

    func recordHistory(_ entry: HistoryEntry) {
        guard configStore.config.history else { return }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    func clearHistory() {
        history.removeAll()
    }

    /// 粘贴后发现用户改掉的词，等用户确认后加入词库。只保存在内存中。
    private(set) var correctionSuggestions: [WordCorrection] = []
    /// 用户忽略过的改动，这次运行期间不再提示。
    @ObservationIgnored private var dismissedCorrections = Set<WordCorrection>()

    /// 记下新发现的改动，返回其中真正新的（已经在替换表里、忽略过的不算）。
    @discardableResult
    func suggestCorrections(_ corrections: [WordCorrection]) -> [WordCorrection] {
        let replacements = configStore.config.replacements
        let fresh = corrections.filter {
            replacements[$0.from] != $0.to && !dismissedCorrections.contains($0) && !correctionSuggestions.contains($0)
        }
        correctionSuggestions.append(contentsOf: fresh)
        return fresh
    }

    /// 加入词库：以后识别出左边的写法时替换成右边的，右边的词也加进常用词。
    func acceptCorrection(_ correction: WordCorrection) {
        configStore.update { config in
            config.replacements[correction.from] = correction.to
            if !config.vocabulary.contains(where: { $0.caseInsensitiveCompare(correction.to) == .orderedSame }) {
                config.vocabulary.append(correction.to)
            }
        }
        correctionSuggestions.removeAll { $0 == correction }
    }

    func dismissCorrection(_ correction: WordCorrection) {
        dismissedCorrections.insert(correction)
        correctionSuggestions.removeAll { $0 == correction }
    }

    static let levelHistory = 24

    private enum Keys {
        static let onboardingCompleted = "onboardingCompleted"
    }

    init() {
        onboardingCompleted = UserDefaults.standard.bool(forKey: Keys.onboardingCompleted)
    }

    var readiness: Readiness {
        if !microphoneGranted { return .needsMicrophone }
        if !accessibilityGranted { return .needsAccessibility }
        if !models.isReady { return .modelNotReady }
        return .ready
    }

    var readinessDescription: String {
        switch readiness {
        // 键名前后的空格由排版规则补上（中文与英文之间加空格，中文之间不加）
        case .ready: Typography.format(String(localized: "就绪：按住\(configStore.config.hotkey.shortName)说话"))
        case .needsMicrophone: String(localized: "需要授权麦克风")
        case .needsAccessibility: String(localized: "需要授权辅助功能")
        case .modelNotReady:
            switch models.status {
            case .downloading(let fraction, _): String(localized: "正在下载语音识别模型 \(Int(fraction * 100))%")
            case .verifying: String(localized: "正在校验语音识别模型")
            default: String(localized: "语音识别模型尚未就绪")
            }
        }
    }

    func refreshPermissions() {
        let mic = Permissions.microphone == .granted
        let ax = Permissions.accessibility
        if mic != microphoneGranted { microphoneGranted = mic }
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.levelHistory)
    }
}

/// 一次说话的结果。
struct HistoryEntry: Identifiable, Equatable {
    enum Kind { case dictation, rewrite, snippet }

    let id = UUID()
    let date: Date
    /// 识别原文（已按替换表替换）；语音改写时是"改写：修改要求"。
    let transcript: String
    /// 实际粘贴的文字。
    let output: String
    var kind: Kind = .dictation

    /// 只有普通的说话输入可以换个方式重新整理。
    var canReprocess: Bool { kind == .dictation }
}
