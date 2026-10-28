import SwiftUI
import TidytalkCore

/// 首次启动引导（设计稿「设置引导」）：麦克风 → 辅助功能 → AI 服务 → 下载识别模型。
/// 左边是欢迎语和四步，右边是当前这一步；页头、内容和底部的左右边距都是 32。每一步都可以先跳过，以后在设置里补。
struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void

    /// 打开时显示的步骤；为 nil 时自动跳到第一个未完成的步骤。
    var initialStep: Step?
    @ViewState private var step: Step = .microphone
    /// 点过“打开辅助功能设置”以后，才显示“打开开关后仍显示未授权”的说明
    @ViewState private var askedAccessibility = false

    enum Step: Int, CaseIterable {
        case microphone, accessibility, ai, model

        /// 侧边栏上的名字
        var title: String {
            switch self {
            case .microphone: String(localized: "授权麦克风")
            case .accessibility: String(localized: "授权辅助功能")
            case .ai: String(localized: "配置 AI")
            case .model: String(localized: "下载识别模型")
            }
        }

        /// 侧边栏上名字下面的一句
        var help: String {
            switch self {
            case .microphone: String(localized: "说话时录音")
            case .accessibility: String(localized: "快捷键和粘贴")
            case .ai: String(localized: "整理文字，可以跳过")
            case .model: String(localized: "在本机识别")
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

        /// 功能色：麦克风红、辅助功能蓝、AI 紫、识别模型青
        var tint: Color {
            switch self {
            case .microphone: Theme.Tint.dictation
            case .accessibility: Theme.Tint.meeting
            case .ai: Theme.Tint.ai
            case .model: Theme.Tint.speech
            }
        }
    }

    var body: some View {
        AppShell(width: 260) {
            sidebar
        } content: {
            VStack(spacing: 0) {
                PageHeader {
                    PageTitle(title: String(localized: "设置引导"))
                } trailing: {
                    Text(verbatim: "\(step.rawValue + 1) / \(Step.allCases.count)")
                        .font(Theme.body.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                // 步骤内容可能比窗口高（例如 AI 配置），放进滚动区域，底部按钮始终可见
                PageBody(spacing: 16) {
                    stepHeader
                    stepContent
                }
                footer
            }
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
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
        // 允许以后自动进入下一步
        .onChange(of: model.microphoneGranted) { if model.microphoneGranted, step == .microphone { move(1) } }
        .onChange(of: model.accessibilityGranted) { if model.accessibilityGranted, step == .accessibility { move(1) } }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            welcome
                .padding(.top, 4)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Step.allCases, id: \.self) { item in
                    StepRow(step: item, done: isComplete(item), selected: item == step) { step = item }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 与 Dock、访达里看到的应用图标一致
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎使用 Tidytalk")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("按住 \(model.configStore.config.hotkey.symbol) 说话，松开后整理好的文字出现在光标处。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 当前步骤

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: step.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(step.tint)
                .frame(width: 44, height: 44)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(stepTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(Theme.titleTracking)
                    .foregroundStyle(Theme.text)
                Text(stepDescription)
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .microphone: String(localized: "允许 Tidytalk 使用麦克风")
        case .accessibility: String(localized: "允许辅助功能")
        case .ai: String(localized: "配置 AI")
        case .model: String(localized: "下载语音识别模型")
        }
    }

    private var stepDescription: String {
        switch step {
        case .microphone: String(localized: "只在你按住快捷键时录音。声音在这台 Mac 上识别，不会上传。")
        case .accessibility: String(localized: "用来监听快捷键、把文字粘贴到光标处。Tidytalk 不会读取你输入的其他内容。")
        case .ai: String(localized: "用 AI 去掉“嗯、那个”，修正口误和标点。选 Ollama、LM Studio 或 Apple 智能时不联网。")
        case .model: String(localized: "在这台 Mac 上识别语音，支持中文、英文、日文、韩文和粤语，自动判断语言。")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .microphone:
            PermissionCard(symbol: "mic", title: String(localized: "麦克风"),
                           detail: model.microphoneGranted ? String(localized: "说话时录音")
                               : Permissions.microphone == .denied ? String(localized: "已经拒绝过，要在系统设置里打开")
                               : String(localized: "点右边的按钮，macOS 会弹出询问"),
                           granted: model.microphoneGranted) {
                if Permissions.microphone == .notDetermined {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        model.refreshPermissions()
                    }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            }

        case .accessibility:
            if !model.accessibilityGranted {
                VStack(alignment: .leading, spacing: 10) {
                    NumberedLine(1, String(localized: "点下面的按钮，打开“系统设置 › 隐私与安全性 › 辅助功能”"))
                    NumberedLine(2, String(localized: "在列表里打开 Tidytalk 的开关"))
                    NumberedLine(3, String(localized: "回到这里，会自动进入下一步"))
                }
            }
            PermissionCard(symbol: "accessibility", title: String(localized: "辅助功能"),
                           detail: String(localized: "监听快捷键、粘贴文字"), granted: model.accessibilityGranted) {
                askedAccessibility = true
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if askedAccessibility && !model.accessibilityGranted {
                NoteBox { AccessibilityHelp(model: model) }
            }

        case .ai:
            SettingsRow(String(localized: "整理文字"), help: String(localized: "关闭后直接输出识别结果")) {
                Toggle("整理文字", isOn: Binding(get: { model.cleanupEnabled }, set: { model.cleanupEnabled = $0 }))
                    .labelsHidden()
            }
            .cardStyle()
            AIConfigEditor(model: model, compact: true)
                .disabled(!model.cleanupEnabled)

        case .model:
            ModelProgressCard(model: model)
            NoteBox {
                Text("下载完就能用。想要更准，以后可以换成 Qwen3-ASR（\(Self.size(of: .qwen3ASR))）。")
            }
        }
    }

    private static func size(of speechModel: SpeechModel) -> String {
        ByteCountFormatter.string(fromByteCount: speechModel.spec?.totalSize ?? 0, countStyle: .file)
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            // 每一步都告诉用户以后在哪里改
            Text(laterHint)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            if step != .microphone {
                IconButton("chevron.left", help: "上一步", size: 36, outlined: true) { move(-1) }
            }
            if step == Step.allCases.last {
                // 没有模型就无法识别，下载完成前不能结束引导
                IconButton("checkmark", help: "完成（回车）", size: 36,
                           tint: model.models.isReady ? nil : Theme.tertiaryText, prominent: true) {
                    model.onboardingCompleted = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.models.isReady)
            } else {
                // 这一步还没做完时是灰色，点了先跳过
                IconButton("arrow.right", help: isComplete(step) ? "下一步（回车）" : "先跳过这一步", size: 36,
                           tint: isComplete(step) ? nil : Theme.tertiaryText, prominent: true) { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .frame(height: 64)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var laterHint: String {
        switch step {
        case .microphone, .accessibility: String(localized: "以后也可以在“设置 › 隐私与数据”里允许")
        case .ai: String(localized: "可以跳过，以后在“设置 › AI 服务”里配置")
        case .model: String(localized: "以后可以在“设置 › 识别模型”里换用其他模型")
        }
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
}

/// 侧边栏里的一步：圆圈里是序号（做完了是黑底白勾），名字和一句说明。选中时是浅灰底。
private struct StepRow: View {
    let step: OnboardingView.Step
    let done: Bool
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(Theme.bodyMedium)
                        .foregroundStyle(selected || done ? Theme.text : Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(step.help).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var mark: some View {
        if done {
            Circle().fill(Theme.accent).frame(width: 22, height: 22)
                .overlay { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accentForeground) }
        } else {
            Circle().fill(Theme.panel).frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(selected ? Theme.text : Theme.border, lineWidth: selected ? 1.5 : 1) }
                .overlay {
                    Text(verbatim: String(step.rawValue + 1)).font(Theme.smallMedium)
                        .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                }
        }
    }
}

/// 一项权限：图标、名字和说明，右边是状态（还没允许黄、已允许绿）和打开系统设置的按钮。
private struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                Text(detail).font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                PropertyChip(symbol: "checkmark.circle", text: String(localized: "已允许"), tint: Theme.Tint.local)
            } else {
                PropertyChip(symbol: "exclamationmark.circle", text: String(localized: "还没允许"), tint: Theme.Tint.progress)
                IconButton("arrow.up.right", help: "打开系统设置", prominent: true, action: action)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .cardStyle()
    }
}

/// 带序号的一行说明（1 点下面的按钮…）。
private struct NumberedLine: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: String(number)).font(Theme.smallMedium).foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .background(Theme.subtle, in: Circle())
            Text(text).font(Theme.body).foregroundStyle(Theme.text)
        }
    }
}

/// 下载识别模型：名字和大小、百分比、进度条，下面一行写已下载多少、从哪里下载。
private struct ModelProgressCard: View {
    let model: AppModel

    private var manager: ModelManager { model.models }
    private var total: Int64 { manager.totalSize ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.configStore.config.speechModel.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(Theme.small).foregroundStyle(Theme.secondaryText)
                Spacer()
                switch manager.status {
                case .ready:
                    Text("已下载").font(Theme.bodySemibold).foregroundStyle(Theme.Tint.local)
                case .downloading(let fraction, _):
                    Text(verbatim: "\(Int(fraction * 100))%").font(Theme.bodySemibold.monospacedDigit()).foregroundStyle(Theme.text)
                case .missing, .failed:
                    IconButton("arrow.down.to.line", help: "下载模型", tint: Theme.Tint.speech, prominent: true) { manager.download() }
                case .verifying:
                    EmptyView()
                }
            }
            ThinProgress(fraction: fraction, tint: Theme.Tint.speech)
            Text(detail).font(Theme.small).foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardStyle()
        // 一打开这一步就开始下载
        .onAppear { if manager.status == .missing { manager.download() } }
    }

    private var fraction: Double? {
        switch manager.status {
        case .ready: 1
        case .downloading(let fraction, _): fraction
        case .verifying: nil
        case .missing, .failed: 0
        }
    }

    private var statusColor: Color {
        if case .failed = manager.status { return Theme.danger }
        return Theme.secondaryText
    }

    private var detail: String {
        switch manager.status {
        case .ready:
            String(localized: "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · 保存在这台 Mac 上")
        case .downloading(let fraction, let source):
            String(localized: "已下载 \(ByteCountFormatter.string(fromByteCount: Int64(Double(total) * fraction), countStyle: .file)) · 从 \(source) 下载，失败时自动换成镜像")
        case .verifying: String(localized: "正在校验文件…")
        case .missing: String(localized: "需要下载约 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))，之后可以离线识别")
        case .failed(let message): message
        }
    }
}

/// 浅灰底的说明框：圆圈 i 图标和一段灰字（设计稿里引导页底下的说明）。
struct NoteBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12, weight: .medium))
            content()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
