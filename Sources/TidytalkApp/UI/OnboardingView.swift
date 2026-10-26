import SwiftUI
import TidytalkCore

/// 首次启动引导：麦克风 → 辅助功能 → API Key → 下载模型。
/// 和主窗口一样左边是侧边栏（欢迎语和步骤），右边的面板显示当前这一步。
struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void

    /// 打开时显示的步骤；为 nil 时自动跳到第一个未完成的步骤。
    var initialStep: Step?
    @ViewState private var step: Step = .microphone

    enum Step: Int, CaseIterable {
        case microphone, accessibility, ai, model

        var title: String {
            switch self {
            case .microphone: String(localized: "授权麦克风")
            case .accessibility: String(localized: "授权辅助功能")
            case .ai: String(localized: "配置 AI")
            case .model: String(localized: "下载语音识别模型")
            }
        }

        /// 和设置里对应页的图标一致
        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .accessibility: "accessibility"
            case .ai: "sparkles"
            case .model: "waveform"
            }
        }

        /// 功能色：麦克风红、AI 紫、识别模型青；辅助功能是系统设置，用中性灰
        var tint: Color {
            switch self {
            case .microphone: Theme.Tint.dictation
            case .accessibility: Theme.Tint.neutral
            case .ai: Theme.Tint.ai
            case .model: Theme.Tint.speech
            }
        }
    }

    var body: some View {
        AppShell {
            sidebar
        } content: {
            VStack(spacing: 0) {
                PageHeader {
                    PageTitle(title: String(localized: "设置引导"))
                } trailing: {
                    Text(verbatim: "\(step.rawValue + 1) / \(Step.allCases.count)")
                        .font(Theme.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                }
                // 步骤内容可能比窗口高（例如 AI 配置），放进滚动区域，底部按钮始终可见
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stepHeader
                        VStack(alignment: .leading, spacing: 12) {
                            stepContent
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(width: 780, height: 600)
        // 标题栏隐藏、内容延伸到标题栏下面，不再让系统按安全区域整体下移（否则底部按钮会被挤出窗口）
        .ignoresSafeArea()
        .onAppear { step = initialStep ?? firstIncompleteStep }
        .task {
            // 用户在系统设置里授权后自动刷新
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            welcome
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Step.allCases, id: \.self) { item in
                    StepRow(step: item, status: status(of: item), selected: item == step) { step = item }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 与 Dock、访达里看到的应用图标一致
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Tidytalk")
                    .font(Theme.heading)
                    .foregroundStyle(Theme.text)
                Text(Typography.format(String(localized: "按住\(model.configStore.config.hotkey.shortName)说话，松开后文字出现在光标处。")))
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 当前步骤

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(step.tint)
                .frame(width: 40, height: 40)
                .background(step.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(step.tint.opacity(0.22)))
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(Theme.title)
                    .foregroundStyle(Theme.text)
                stepDescription
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepDescription: Text {
        switch step {
        case .microphone:
            Text("用于录音。声音只在这台 Mac 上识别，不会上传。")
        case .accessibility:
            Text(Typography.format(String(localized: "用于监听\(model.configStore.config.hotkey.shortName)键，并把文字输入到光标处。")))
        case .ai:
            Text("去掉\"嗯、那个\"，修正口误和标点。选 Ollama、LM Studio 或 Apple 智能时不联网。可以跳过，直接输出识别结果。")
        case .model:
            Text("在这台 Mac 上识别语音，支持中文、英文、日文、韩文和粤语，自动判断语言。")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .microphone:
            if model.microphoneGranted {
                granted
            } else if Permissions.microphone == .denied {
                Callout {
                    StatusIcon(kind: .failed)
                    Text("麦克风权限已关闭，请在系统设置中打开。").foregroundStyle(Theme.text)
                }
                RoundIconButton(symbol: "gearshape.fill", help: "打开系统设置", tint: Theme.Tint.neutral, size: 44) {
                    Permissions.openMicrophoneSettings()
                }
                .padding(.top, 4)
            } else {
                RoundIconButton(symbol: "mic.fill", help: "授权麦克风", tint: Theme.Tint.dictation, size: 44) {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        model.refreshPermissions()
                    }
                }
            }

        case .accessibility:
            if model.accessibilityGranted {
                granted
            } else {
                Text("点击下方按钮，在系统设置中打开 Tidytalk 的开关。")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                RoundIconButton(symbol: "accessibility", help: "授权辅助功能", tint: Theme.Tint.neutral, size: 44,
                                glyph: 0.46) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                Callout { AccessibilityHelp(model: model) }
                    .padding(.top, 8)
            }

        case .ai:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("整理文字")
                            .font(Theme.bodyMedium)
                            .foregroundStyle(Theme.text)
                        // 云端服务需要 Key，链接放在显眼的位置
                        if AIProvider.detect(model.configStore.config.ai) == .cloud {
                            Link("没有 API Key？获取 DeepSeek API Key",
                                 destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                                .font(Theme.small)
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("整理文字", isOn: Binding(
                        get: { model.cleanupEnabled },
                        set: { model.cleanupEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                AIConfigEditor(model: model)
                    .disabled(!model.cleanupEnabled)
            }
            .padding(16)
            .cardStyle()

        case .model:
            ModelDownloadView(manager: model.models)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            Text("以后可以在\"设置 › 识别模型\"里换用其他模型。")
                .font(Theme.small)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var granted: some View {
        Callout {
            StatusIcon(kind: .done)
            Text("已授权").foregroundStyle(Theme.text)
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.models.isReady {
                Label("下载完成后即可使用", systemImage: "info.circle")
                    .labelStyle(TightLabelStyle())
                    .font(Theme.small)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            if step != .microphone {
                IconButton("chevron.left", help: "上一步", size: 30) { move(-1) }
            }
            if step == Step.allCases.last {
                // 没有模型就无法识别，下载完成前不能结束引导
                IconButton("checkmark", help: "完成（回车）", size: 30, prominent: true) {
                    model.onboardingCompleted = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.models.isReady)
            } else if isComplete(step) {
                IconButton("arrow.right", help: "下一步（回车）", size: 30, prominent: true) { move(1) }
                    .keyboardShortcut(.defaultAction)
            } else {
                IconButton("forward.end", help: "跳过", size: 30) { move(1) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func move(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    private func isComplete(_ step: Step) -> Bool {
        switch step {
        case .microphone: model.microphoneGranted
        case .accessibility: model.accessibilityGranted
        case .ai: model.configStore.config.ai.isConfigured || !model.cleanupEnabled
        case .model: model.models.isReady
        }
    }

    private var firstIncompleteStep: Step {
        Step.allCases.first { !isComplete($0) } ?? .model
    }

    /// 侧边栏上这一步的状态图标；还没开始做时为 nil，显示这一步自己的彩色图标
    private func status(of step: Step) -> StatusIcon.Kind? {
        if isComplete(step) { return .done }
        guard step == .model else { return nil }
        switch model.models.status {
        case .downloading(let fraction, _): return .progress(fraction)
        case .verifying: return .progress(nil)
        case .failed: return .failed
        case .missing, .ready: return nil
        }
    }
}

/// 侧边栏里的一步：彩色图标（完成、下载中、出错时换成状态图标）和名字。选中时是浅灰底。
private struct StepRow: View {
    let step: OnboardingView.Step
    let status: StatusIcon.Kind?
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                badge.frame(width: 18)
                // 英文的"Download Speech Model"比侧边栏宽一点，稍微缩小而不是截断
                Text(step.title)
                    .font(selected ? Theme.bodyMedium : Theme.body)
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var badge: some View {
        if let status {
            StatusIcon(kind: status)
        } else {
            Image(systemName: step.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(step.tint)
        }
    }
}
