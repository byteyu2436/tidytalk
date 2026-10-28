import SwiftUI
import TidytalkCore

/// AI 整理接口（OpenAI 兼容协议）的配置：地址、Key、模型，保存到 `~/.tidytalk.json`。
struct AIConfigEditor: View {
    let model: AppModel
    /// 设置引导里用的简单版：只有服务卡片和一行状态，选云端时才显示接口和 Key
    var compact = false
    @ViewState private var baseURL = ""
    @ViewState private var apiKey = ""
    @ViewState private var modelName = ""
    @ViewState private var timeout = AIConfig.default.timeout
    @ViewState private var testState: TestState = .idle
    @ViewState private var service: AIService = .openAICompatible
    /// 已经从配置文件载入过。切换设置标签页再回来时，有未保存的修改就不重新载入，免得丢掉
    @ViewState private var loaded = false

    enum TestState: Equatable {
        case idle, saved, testing, success(Double), failure(String)
    }

    private var store: ConfigStore { model.configStore }

    private var draft: AIConfig {
        var ai = store.config.ai
        ai.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.timeout = min(300, max(3, timeout))
        ai.service = service
        return ai
    }

    private var isDirty: Bool { draft != store.config.ai }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    providers
                    if service != .apple && !draft.isLocal {
                        connection
                    } else {
                        HStack(spacing: 8) {
                            statusLine
                            Spacer(minLength: 8)
                            testButton
                        }
                    }
                }
            } else {
                // 设置页：「服务」「连接」两组
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    VStack(alignment: .leading, spacing: Theme.titleGap) {
                        Text("服务").font(Theme.heading).foregroundStyle(Theme.text)
                        providers
                    }
                    VStack(alignment: .leading, spacing: Theme.titleGap) {
                        Text("连接").font(Theme.heading).foregroundStyle(Theme.text)
                        connection
                    }
                }
            }
        }
        .onAppear { if !loaded || !isDirty { loadDraft() } }
    }

    private var providers: some View {
        ProviderPicker(selection: AIProvider.detect(draft)) { provider in
            // 再点一次当前这一类不重置，避免把自己改过的云端地址换回 DeepSeek
            guard provider != AIProvider.detect(draft) else { return }
            apply(provider)
        }
    }

    /// 连接：接口地址、API Key、模型、超时，最下面一行是状态、测试和保存。
    private var connection: some View {
        VStack(spacing: 0) {
            if service == .apple {
                Text("使用这台 Mac 自带的 Apple 智能，不需要 API Key，文字不会离开这台 Mac。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                field(String(localized: "接口地址")) {
                    TextField("接口地址", text: $baseURL, prompt: Text(AIConfig.default.baseURL))
                        .textFieldStyle(.plain).linearField()
                }
                divider
                field(String(localized: "API Key")) {
                    SecureField("API Key", text: $apiKey,
                                prompt: Text(draft.isLocal ? String(localized: "本机模型可以不填")
                                             : String(localized: "填你在服务商那里拿到的 API Key")))
                        .textFieldStyle(.plain).linearField()
                }
                divider
                field(String(localized: "模型")) {
                    TextField("模型", text: $modelName,
                              prompt: Text(draft.isLocal ? String(localized: "本机已下载或加载的模型名") : AIConfig.default.model))
                        .textFieldStyle(.plain).linearField()
                }
                divider
                field(String(localized: "超时")) {
                    HStack(spacing: 8) {
                        TextField("超时", value: $timeout, format: .number)
                            .textFieldStyle(.plain).linearField()
                            .frame(width: 80)
                        Text("秒").font(Theme.caption).foregroundStyle(Theme.secondaryText)
                        Spacer()
                    }
                }
            }
            divider
            HStack(spacing: 8) {
                statusLine
                Spacer(minLength: 8)
                testButton
                IconButton("checkmark", help: "保存", prominent: true, action: save)
                    .disabled(!isDirty)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background(Theme.canvas)
        }
        .labelsHidden()
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .cardStyle()
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.bodyMedium).foregroundStyle(Theme.text).frame(width: 100, alignment: .leading)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var testButton: some View {
        IconButton("waveform.path.ecg", help: "测试连接", tint: Theme.Tint.ai, outlined: true, action: test)
            .disabled(testState == .testing || !draft.isConfigured)
    }

    /// 底部一行状态：绿点已连接、灰点还差什么、红点出错。
    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if let error = store.loadError {
                dot(Theme.danger)
                Text(error).foregroundStyle(Theme.danger)
            } else {
                switch testState {
                case .testing:
                    StatusIcon(kind: .progress(nil), size: 12)
                    Text("正在测试…").foregroundStyle(Theme.secondaryText)
                case .success(let seconds):
                    dot(Theme.Tint.local)
                    Text(compact ? connectedText
                         : String(localized: "已连接，响应用了 \(seconds.formatted(.number.precision(.fractionLength(1)))) 秒"))
                        .foregroundStyle(Theme.text)
                case .failure(let message):
                    dot(Theme.danger)
                    Text(message).foregroundStyle(Theme.danger)
                case .saved where !isDirty:
                    dot(Theme.Tint.local)
                    Text("已保存").foregroundStyle(Theme.text)
                default:
                    if isDirty {
                        dot(Theme.Tint.progress)
                        Text("有未保存的修改").foregroundStyle(Theme.secondaryText)
                    } else if let missing {
                        dot(Theme.secondaryText)
                        Text(missing).foregroundStyle(Theme.secondaryText)
                    } else if draft.isLocal || service == .apple {
                        dot(Theme.Tint.local)
                        Text(connectedText).foregroundStyle(Theme.text)
                    } else {
                        dot(Theme.secondaryText)
                        Text("点右边的按钮测试连接").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .font(Theme.caption)
        .lineLimit(2)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    /// 已连上本机 Ollama · qwen3:8b
    private var connectedText: String {
        if service == .apple { return String(localized: "用这台 Mac 自带的 Apple 智能") }
        let provider = AIProvider.detect(draft).map(ProviderPicker.title) ?? (URL(string: draft.baseURL)?.host ?? draft.baseURL)
        let name = draft.model.isEmpty ? provider : "\(provider) · \(draft.model)"
        return draft.isLocal ? String(localized: "已连上本机 \(name)") : String(localized: "已连上 \(name)")
    }

    /// 还差什么才能用：没填接口地址、API Key 或模型。
    private var missing: String? {
        guard service != .apple else { return nil }
        if draft.baseURL.isEmpty { return String(localized: "还差接口地址。填好后点右边的按钮测试") }
        if !draft.isLocal && draft.apiKey.isEmpty { return String(localized: "还差 API Key。填好后点右边的按钮测试") }
        if draft.model.isEmpty { return String(localized: "还差模型名。填好后点右边的按钮测试") }
        return nil
    }

    private func loadDraft() {
        store.reload()
        let ai = store.config.ai
        baseURL = ai.baseURL
        apiKey = ai.apiKey
        modelName = ai.model
        timeout = ai.timeout
        service = ai.service
        loaded = true
    }

    /// 切换服务只改接口地址、模型名和超时，保存前可以再修改；切到 Apple 智能时保留原来填的内容。
    private func apply(_ provider: AIProvider) {
        let ai = provider.applied(to: draft)
        baseURL = ai.baseURL
        modelName = ai.model
        timeout = ai.timeout
        service = ai.service
        testState = .idle
        // 本机模型和 Apple 智能不用填 Key，选了就保存，免得忘了点保存
        if ai.isLocal || ai.service == .apple { save() }
    }

    private func save() {
        let ai = draft
        if store.update({ $0.ai = ai }) { testState = .saved }
    }

    private func test() {
        if isDirty { save() }
        let config = draft
        testState = .testing
        Task {
            let started = Date()
            do {
                try await ChatCompletionClient(config: config).testConnection()
                testState = .success(Date().timeIntervalSince(started))
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

/// AI 服务的四种选择：Ollama、LM Studio（都在本机运行）、云端接口和 Apple 智能，带各自的图标，两行两列。
/// Apple 智能只在这台 Mac 支持并已打开时才能选，否则变灰并写明原因。
struct ProviderPicker: View {
    let selection: AIProvider?
    let choose: (AIProvider) -> Void
    @ViewState private var appleUnavailable = AppleIntelligence.unavailableReason

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                card(.ollama)
                card(.lmStudio)
            }
            GridRow {
                card(.cloud)
                card(.apple)
            }
        }
        .task {
            // 用户可能刚在系统设置里打开 Apple 智能
            while !Task.isCancelled {
                let reason = AppleIntelligence.unavailableReason
                if reason != appleUnavailable { appleUnavailable = reason }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func card(_ provider: AIProvider) -> some View {
        let disabled = provider == .apple && appleUnavailable != nil && selection != .apple
        let selected = provider == selection
        return Button { choose(provider) } label: {
            HStack(spacing: 12) {
                Self.iconView(provider)
                    .frame(width: 32, height: 32)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(provider)).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text(provider == .apple ? (appleUnavailable ?? Self.detail(provider)) : Self.detail(provider))
                        .font(Theme.small).foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .help(provider == .apple ? (appleUnavailable ?? "") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 设计稿的图标：本机芯片、服务器、云、Apple 智能的星星。
    @ViewBuilder
    static func iconView(_ provider: AIProvider) -> some View {
        switch provider {
        case .ollama: Image(systemName: "cpu").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
        case .lmStudio: Image(systemName: "server.rack").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Tint.ai)
        case .cloud: Image(systemName: "cloud").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Tint.meeting)
        case .apple: Image(systemName: "sparkle").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Tint.ai)
        }
    }

    static func title(_ provider: AIProvider) -> String {
        switch provider {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .cloud: String(localized: "云端")
        case .apple: String(localized: "Apple 智能")
        }
    }

    static func detail(_ provider: AIProvider) -> String {
        switch provider {
        case .ollama, .lmStudio: String(localized: "本机运行")
        case .cloud: String(localized: "DeepSeek、OpenAI 等")
        case .apple: String(localized: "macOS 自带，不用下载")
        }
    }
}

/// 设置里的识别模型列表：每个模型可以下载、使用、删除。
struct SpeechModelList: View {
    let model: AppModel

    var body: some View {
        ForEach(SpeechModel.allCases, id: \.self) { speechModel in
            SpeechModelRow(model: model, speechModel: speechModel)
        }
        .onAppear { model.modelManagers[.apple]?.refreshAppleStatus() }
    }
}

private struct SpeechModelRow: View {
    let model: AppModel
    let speechModel: SpeechModel
    @ViewState private var hovering = false

    private var manager: ModelManager { model.modelManagers[speechModel]! }
    private var isSelected: Bool { model.configStore.config.speechModel == speechModel }

    // 设计稿：左边是单选圈（选中的是粗黑圈），名字、大小和说明；右边按状态是“正在用”、删除、下载或进度
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().strokeBorder(isSelected ? Theme.accent : Theme.borderStrong, lineWidth: isSelected ? 5 : 1.5)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speechModel.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text(sizeText).font(Theme.small).foregroundStyle(Theme.secondaryText)
                    if speechModel == .senseVoice {
                        Text("默认")
                            .font(Theme.micro)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.border))
                    }
                }
                Text(speechModel.summary)
                    .font(Theme.small)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = manager.status {
                    Text(message).font(Theme.small).foregroundStyle(Theme.danger)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? Theme.canvas : hovering && manager.isReady ? Theme.hover : .clear)
        .contentShape(Rectangle())
        // 点下载好的模型就换用它
        .onTapGesture { if manager.isReady, !isSelected { model.useSpeechModel(speechModel) } }
        .onHover { hovering = $0 }
    }

    private var sizeText: String {
        guard let size = manager.totalSize else { return String(localized: "系统自带") }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    @ViewBuilder
    private var action: some View {
        switch manager.status {
        case .ready:
            if isSelected {
                Text("正在用").font(Theme.small).foregroundStyle(Theme.secondaryText)
            } else if manager.canDelete {
                IconButton("trash", help: "删除下载的文件", size: 28, destructive: true) { manager.delete() }
            }
        case .missing:
            // Apple 系统识别的模型由系统下载，按钮叫"启用"
            if speechModel == .apple {
                IconButton("power", help: "启用", size: 28, tint: Theme.Tint.speech) { model.useSpeechModel(speechModel) }
            } else {
                IconButton("arrow.down.to.line", helpText: isSelected ? String(localized: "下载") : String(localized: "下载并使用"),
                           tint: Theme.Tint.speech, outlined: true) {
                    model.useSpeechModel(speechModel)
                }
            }
        case .downloading(let fraction, _):
            DownloadProgress(fraction: fraction, canCancel: manager.spec != nil) { manager.cancel() }
        case .verifying:
            HStack(spacing: 6) {
                StatusIcon(kind: .progress(nil), size: 12)
                Text("正在校验…").font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
        case .failed:
            if manager.needsRedownload {
                IconButton("arrow.clockwise", help: "重新下载", tint: Theme.Tint.speech, outlined: true) {
                    manager.redownload()
                    model.useSpeechModel(speechModel)
                }
            } else {
                IconButton("arrow.down.to.line", help: "继续下载", tint: Theme.Tint.speech, outlined: true) {
                    model.useSpeechModel(speechModel)
                }
            }
        }
    }
}

/// 下载中：百分比、青色进度条和取消。
struct DownloadProgress: View {
    let fraction: Double
    var canCancel = true
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(Int(fraction * 100))%").font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            ThinProgress(fraction: fraction, tint: Theme.Tint.speech).frame(width: 120)
            if canCancel {
                IconButton("xmark", help: "取消下载", size: 28, action: onCancel)
            }
        }
    }
}

/// 说话人模型（设计稿「识别模型 › 说话人模型」）：图标、名字、大小和说明，右边是已下载和删除，或者下载。
struct DiarizationModelRow: View {
    let manager: ModelManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Tint.meeting)
                .frame(width: 32, height: 32)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("区分说话人").font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Text(ByteCountFormatter.string(fromByteCount: manager.totalSize ?? 0, countStyle: .file))
                        .font(Theme.small).foregroundStyle(Theme.secondaryText)
                }
                Text("会议记录结束后，把对方分成说话人 1、2、3，可以改名")
                    .font(Theme.small).foregroundStyle(Theme.secondaryText)
                if case .failed(let message) = manager.status {
                    Text(message).font(Theme.small).foregroundStyle(Theme.danger)
                }
            }
            Spacer(minLength: 8)
            switch manager.status {
            case .ready:
                PropertyChip(symbol: "checkmark.circle", text: String(localized: "已下载"), tint: Theme.Tint.local)
                if manager.canDelete {
                    IconButton("trash", help: "删除下载的文件", size: 28, destructive: true) { manager.delete() }
                }
            case .downloading(let fraction, _):
                DownloadProgress(fraction: fraction) { manager.cancel() }
            case .verifying:
                StatusIcon(kind: .progress(nil), size: 12)
            case .missing, .failed:
                IconButton("arrow.down.to.line", help: "下载说话人模型", tint: Theme.Tint.speech, outlined: true) {
                    manager.download()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        HStack(spacing: 8) {
            Text("打开开关后仍显示未授权？在列表中选中 Tidytalk 点\"−\"删除，再点\"授权\"重新添加。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if checking {
                StatusIcon(kind: .progress(nil)).frame(width: 24, height: 24)
            } else {
                IconButton("arrow.clockwise", help: "重新检测", size: 24) {
                    checking = true
                    model.refreshPermissions()
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        checking = false
                    }
                }
            }
        }
    }
}
