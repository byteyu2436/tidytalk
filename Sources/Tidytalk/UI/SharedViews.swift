import SwiftUI
import TidytalkCore

/// AI 整理接口（OpenAI 兼容协议）的配置：地址、Key、模型，保存到 `~/.tidytalk.json`。
struct AIConfigEditor: View {
    let model: AppModel
    @ViewState private var baseURL = ""
    @ViewState private var apiKey = ""
    @ViewState private var modelName = ""
    @ViewState private var timeout = AIConfig.default.timeout
    @ViewState private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, saved, testing, success, failure(String)
    }

    private var store: ConfigStore { model.configStore }

    private var draft: AIConfig {
        var ai = store.config.ai
        ai.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.timeout = min(300, max(3, timeout))
        return ai
    }

    private var isDirty: Bool { draft != store.config.ai }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderPicker(selection: AIProvider.detect(draft)) { provider in
                // 再点一次当前这一类不重置，避免把自己改过的云端地址换回 DeepSeek
                guard provider != AIProvider.detect(draft) else { return }
                apply(provider.preset)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("接口地址").gridColumnAlignment(.trailing)
                    TextField("接口地址", text: $baseURL, prompt: Text(AIConfig.default.baseURL))
                }
                GridRow {
                    Text(verbatim: "API Key")  // 技术名词，各语言相同
                    SecureField("API Key", text: $apiKey, prompt: Text(draft.isLocal ? String(localized: "本机模型可以不填") : "sk-…"))
                }
                GridRow {
                    Text("模型")
                    TextField("模型", text: $modelName,
                              prompt: Text(draft.isLocal ? String(localized: "本机已下载或加载的模型名") : AIConfig.default.model))
                }
                GridRow {
                    Text("超时")
                    HStack(spacing: 6) {
                        TextField("超时", value: $timeout, format: .number)
                            .frame(width: 60)
                        Text("秒").foregroundStyle(.secondary)
                    }
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)

            HStack {
                Button("保存", action: save)
                    .disabled(!isDirty)
                Button("测试连接", action: test)
                    .disabled(testState == .testing || !draft.isConfigured)
                Spacer()
                Button("打开配置文件") { store.openInEditor() }
                    .buttonStyle(.link)
            }

            status
                .font(.callout)
        }
        .onAppear(perform: loadDraft)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if let error = store.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                switch testState {
                case .idle:
                    if isDirty {
                        Text("有未保存的修改").foregroundStyle(.secondary)
                    } else if draft.isLocal {
                        Label("使用本机模型，文字不会离开这台 Mac", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                case .saved:
                    Label("已保存", systemImage: "checkmark").foregroundStyle(.secondary)
                case .testing:
                    ProgressView().controlSize(.small)
                    Text("正在测试…").foregroundStyle(.secondary)
                case .success:
                    Label("连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
    }

    private func loadDraft() {
        store.reload()
        let ai = store.config.ai
        baseURL = ai.baseURL
        apiKey = ai.apiKey
        modelName = ai.model
        timeout = ai.timeout
    }

    /// 套用预设只改接口地址、模型名和超时，保存前可以再修改。
    private func apply(_ preset: AIPreset) {
        let ai = preset.applied(to: draft)
        baseURL = ai.baseURL
        modelName = ai.model
        timeout = ai.timeout
        testState = .idle
    }

    private func save() {
        var config = store.config
        config.ai = draft
        if store.save(config) { testState = .saved }
    }

    private func test() {
        if isDirty { save() }
        let config = draft
        testState = .testing
        Task {
            do {
                try await ChatCompletionClient(config: config).testConnection()
                testState = .success
            } catch {
                testState = .failure(Self.describe(error))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return String(localized: "网络不可用")
            case .timedOut: return String(localized: "连接超时")
            case .cannotFindHost, .cannotConnectToHost: return String(localized: "无法连接到接口地址")
            default: return String(localized: "连接失败：\(error.localizedDescription)")
            }
        }
        return error.localizedDescription
    }
}

/// AI 服务的三种选择：Ollama、LM Studio（都在本机运行）和云端接口，带各自的图标。
struct ProviderPicker: View {
    let selection: AIProvider?
    let choose: (AIProvider) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                Button { choose(provider) } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(provider))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(provider)).font(.callout.weight(.semibold))
                            Text(Self.detail(provider)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(ProviderButtonStyle(isSelected: provider == selection))
                .accessibilityAddTraits(provider == selection ? .isSelected : [])
            }
        }
    }

    static func title(_ provider: AIProvider) -> String {
        switch provider {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .cloud: String(localized: "云端")
        }
    }

    static func detail(_ provider: AIProvider) -> String {
        switch provider {
        case .ollama, .lmStudio: String(localized: "本机运行")
        case .cloud: String(localized: "DeepSeek 等")
        }
    }

    /// 图标随应用打包在 Resources/ProviderIcons 里；直接用 swift run 运行时没有，就用系统图标代替。
    static func icon(_ provider: AIProvider) -> NSImage {
        let name = switch provider {
        case .ollama: "ollama"
        case .lmStudio: "lmstudio"
        case .cloud: "cloud"
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderIcons"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: provider == .cloud ? "cloud" : "desktopcomputer", accessibilityDescription: nil)!
    }
}

private struct ProviderButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
    }
}

/// 语音识别模型的下载状态和操作。
struct ModelDownloadView: View {
    let manager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch manager.status {
            case .ready:
                Label("语音识别模型已就绪", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .missing:
                Text("需要下载约 \(sizeText)，之后可离线识别。")
                    .foregroundStyle(.secondary)
                Button("下载模型") { manager.download() }
                    .buttonStyle(.borderedProminent)
            case .downloading(let fraction, _):
                ProgressView(value: fraction) {
                    Text("正在下载… \(Int(fraction * 100))%")
                        .font(.callout)
                }
                Button("暂停") { manager.cancel() }
            case .verifying:
                ProgressView { Text("正在校验文件…").font(.callout) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("继续下载") { manager.download() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: manager.spec.totalSize, countStyle: .file)
    }
}

/// 权限状态行。
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(actionTitle, action: action)
            }
        }
    }
}

/// 辅助功能开关已打开、应用却仍未获得授权时的处理说明。
///
/// 常见原因是列表里的 Tidytalk 对应的是旧版本（重新安装或重新编译后签名变化），
/// 需要删除后重新添加。
struct AccessibilityHelp: View {
    let model: AppModel
    @ViewState private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("打开开关后仍显示未授权？在列表中选中 Tidytalk 点\"−\"删除，再点\"授权\"重新添加。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("重新检测") {
                    checking = true
                    model.refreshPermissions()
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        checking = false
                    }
                }
                .controlSize(.small)
                if checking {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }
}
