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
    /// 正在录音、但麦克风还没送来真正的声音（蓝牙耳机切换到通话模式要一两秒）：电平条变暗、缓慢闪烁。
    var waitingForInput = false
    /// 最近的电平，最新的在末尾。
    private(set) var levels: [Float] = Array(repeating: 0, count: AppModel.levelHistory)

    /// 实时字幕：是否正在收听电脑的声音、是否暂停、显示的文字。
    var isListening = false
    var listeningPaused = false
    var captions = CaptionTranscript()

    /// 会议：正在录、或者录完还在识别和分说话人。这期间不能释放识别模型。
    var meetingRecording = false
    var meetingProcessing = false
    var meetingActive: Bool { meetingRecording || meetingProcessing }

    /// 会议模式的说话人模型（和识别模型分开管理，不会被当成识别器加载）。
    let diarizationModels = ModelManager(spec: .speakerDiarization)

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
        // 之前点过别的模型"下载并使用"、还没下载完：以这次的选择为准，免得那边下载完后又被切过去
        for (other, otherManager) in modelManagers where other != speechModel { otherManager.useWhenReady = nil }
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
        set { configStore.update { $0.cleanupEnabled = newValue } }
    }

    var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// 说话记录。打开"保存说话记录"时存在这台 Mac 上，超过保留天数自动删除；关闭时只在内存里。
    let dictations: DictationStore

    /// 最近的说话记录，最新的在前。
    var history: [HistoryEntry] { dictations.entries }

    func recordHistory(_ entry: HistoryEntry) {
        dictations.add(entry)
    }

    func clearHistory() {
        dictations.clear()
    }

    /// 改"保存说话记录"和保留天数（设置 › 隐私与数据）。
    func setHistory(saving: Bool? = nil, days: Int? = nil) {
        configStore.update { config in
            if let saving { config.history = saving }
            if let days { config.historyDays = days }
        }
        dictations.configure(saving: configStore.config.history, retentionDays: configStore.config.historyDays)
    }

    /// 老用户升级后第一次打开资料库时提示一次：说话记录现在会保存、在哪里关。
    private(set) var dictationNoticePending: Bool

    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 截图用：显示升级提示、放几条“发现你改过的词”。
    func simulate(notice: Bool? = nil, suggestions: [WordCorrection]? = nil) {
        if let notice { dictationNoticePending = notice }
        if let suggestions { correctionSuggestions = suggestions }
    }
    #endif

    /// 录制系统音频的权限：macOS 不提供查询接口，按收到过的声音判断。收听或开会时听到过电脑的声音算已允许；
    /// 有别的应用在发声、收到的却一直是静音算还没允许；都没试过时不知道。
    enum SystemAudioStatus: String { case unknown, granted, denied }

    var systemAudio: SystemAudioStatus = SystemAudioStatus(
        rawValue: UserDefaults.standard.string(forKey: "systemAudioStatus") ?? "") ?? .unknown

    func noteSystemAudio(heard: Bool) {
        let status: SystemAudioStatus = heard ? .granted : .denied
        guard status != systemAudio else { return }
        systemAudio = status
        UserDefaults.standard.set(status.rawValue, forKey: "systemAudioStatus")
    }

    func dismissDictationNotice() {
        dictationNoticePending = false
        if !Self.isScratchRun { UserDefaults.standard.set(true, forKey: Keys.dictationNoticeShown) }
    }

    /// 开发用的截图命令（`--config` 指定临时配置）不改真实的偏好设置。
    private static var isScratchRun: Bool {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        CommandLine.arguments.contains("--config")
        #else
        false
        #endif
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
        /// 资料库里"说话记录现在会保存"的提示看过了
        static let dictationNoticeShown = "dictationNoticeShown"
    }

    init() {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: Keys.onboardingCompleted)
        onboardingCompleted = completed
        let config = configStore.config
        dictations = DictationStore(saving: config.history, retentionDays: config.historyDays)
        // 只提示升级上来的老用户（以前完成过设置引导）；新用户在引导里就知道了
        if defaults.object(forKey: Keys.dictationNoticeShown) == nil {
            dictationNoticePending = completed && config.history
            if !completed && !Self.isScratchRun { defaults.set(true, forKey: Keys.dictationNoticeShown) }
        } else {
            dictationNoticePending = false
        }
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

/// 一次说话的结果。保存说话记录时写进 `Dictations/dictations.json`。
struct HistoryEntry: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case dictation, rewrite, snippet }

    var id = UUID()
    let date: Date
    /// 识别原文（已按替换表替换）；语音改写时是"改写：修改要求"。
    let transcript: String
    /// 实际粘贴的文字。
    let output: String
    var kind: Kind = .dictation

    /// 只有普通的说话输入可以换个方式重新整理。
    var canReprocess: Bool { kind == .dictation }
}
