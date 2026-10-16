import SwiftUI
import TidytalkCore

/// 首次启动引导：麦克风 → 辅助功能 → API Key → 下载模型。
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏透明并隐藏了标题，顶部留出红绿灯按钮的位置
            header
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 20)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                stepList
                    .frame(width: 200)
                    .padding(.vertical, 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                // 步骤内容可能比窗口高（例如 AI 配置），放进滚动区域，底部按钮始终可见
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(step.title).font(.title2.weight(.semibold))
                        stepContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 640, height: 560)
        // 顶部已经手动留出标题栏的高度，不再让系统按安全区域整体下移（否则底部按钮会被挤出窗口）
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

    private var header: some View {
        HStack(spacing: 14) {
            // 与 Dock、访达里看到的应用图标一致
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Tidytalk").font(.title.weight(.semibold))
                Text(Typography.format(String(localized: "按住\(model.configStore.config.hotkey.shortName)说话，松开后文字出现在光标处。")))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Step.allCases, id: \.self) { item in
                Button {
                    step = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isComplete(item) ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle")
                            .foregroundStyle(isComplete(item) ? .green : .secondary)
                        Text(item.title)
                            .fontWeight(item == step ? .semibold : .regular)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(item == step ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .microphone:
            Text("用于录音。声音只在这台 Mac 上识别，不会上传。")
                .foregroundStyle(.secondary)
            if model.microphoneGranted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if Permissions.microphone == .denied {
                Text("麦克风权限已关闭，请在系统设置中打开。").foregroundStyle(.orange)
                Button("打开系统设置") { Permissions.openMicrophoneSettings() }
            } else {
                Button("授权麦克风") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        model.refreshPermissions()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

        case .accessibility:
            Text(Typography.format(String(localized: "用于监听\(model.configStore.config.hotkey.shortName)键，并把文字输入到光标处。")))
                .foregroundStyle(.secondary)
            if model.accessibilityGranted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("点击下方按钮，在系统设置中打开 Tidytalk 的开关。")
                    .font(.callout)
                HStack {
                    Button("授权辅助功能") {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                AccessibilityHelp(model: model)
            }

        case .ai:
            Text("文字会发送给你配置的 AI 服务，去掉\"嗯、那个\"并修正口误。可以跳过，直接输出识别结果。")
                .foregroundStyle(.secondary)
            AIConfigEditor(model: model)
            Toggle("整理文字", isOn: Binding(
                get: { model.cleanupEnabled },
                set: { model.cleanupEnabled = $0 }
            ))
            Link("获取 DeepSeek API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                .font(.callout)

        case .model:
            Text("在这台 Mac 上识别语音，支持中文、英文、日文、韩文和粤语，自动判断语言。")
                .foregroundStyle(.secondary)
            ModelDownloadView(manager: model.models)
        }
    }

    private var footer: some View {
        HStack {
            if !model.models.isReady {
                Label("下载完成后即可使用", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if step != .microphone {
                Button("上一步") { move(-1) }
            }
            if step == Step.allCases.last {
                Button("完成") {
                    model.onboardingCompleted = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                if isComplete(step) {
                    Button("下一步") { move(1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("跳过") { move(1) }
                }
            }
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
