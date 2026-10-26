import AppKit
import SwiftUI
import TidytalkCore

/// 设置里的「会议」页：录音、说话人模型、AI 总结和占用空间。
struct MeetingSettings: View {
    let model: AppModel
    let store: MeetingStore
    @ViewState private var apps: [AudioSourceApp] = []
    @ViewState private var size: Int64 = 0

    private var config: AppConfig { model.configStore.config }

    var body: some View {
        Form {
            Section {
                LabeledContent("开始或结束", value: "⌃⌥M")
                Picker("收听来源", selection: model.configStore.binding(\.meetingSource)) {
                    Text("全部声音").tag("")
                    if !sourceChoices.isEmpty { Divider() }
                    ForEach(sourceChoices, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                Toggle("会后保留录音", isOn: model.configStore.binding(\.meetingKeepRecording))
            } header: {
                Text("录音")
            } footer: {
                Text("同时录你的麦克风（用\"说话输入\"里选的麦克风）和电脑里会议的声音。只收听某个会议应用时，其他应用的声音不会录进去。保留录音可以回放每一句、重新分说话人，一小时约 30 MB；关掉后处理完只留文字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ModelDownloadView(manager: model.diarizationModels, readyTitle: "说话人模型已就绪")
            } header: {
                Text("区分说话人")
            } footer: {
                Text("会议结束后，在这台 Mac 上把对方分成说话人 1、2、3，你可以给他们改名；几个人同时说话的地方会标出来。没有下载时只分\"我\"和\"对方\"。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("会议结束后自动生成总结", isOn: model.configStore.binding(\.meetingAutoSummary))
                    .disabled(!config.ai.isConfigured)
            } header: {
                Text("AI 总结")
            } footer: {
                Text(config.ai.isConfigured ? MeetingProcessor.destination(config.ai)
                     : String(localized: "需要先在\"配置 AI\"里选好服务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("会议记录占用") {
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        IconButton("folder", help: "在访达中显示", size: 26, tint: Theme.Tint.meeting) {
                            try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([store.root])
                        }
                    }
                }
            } header: {
                Text("存储")
            } footer: {
                Text("会议的文字和录音只保存在这台 Mac 上（~/Library/Application Support/Tidytalk/Meetings），在 Tidytalk 主窗口里可以逐个删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                let playing = AudioProcesses.playingApps()
                if playing != apps { apps = playing }
                size = store.totalSize()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 正在发声的应用，加上已经选中但现在没有声音的那个。
    private var sourceChoices: [AudioSourceApp] {
        let current = config.meetingSource
        guard !current.isEmpty, !apps.contains(where: { $0.bundleID == current }) else { return apps }
        return [AudioSourceApp(bundleID: current, name: AudioProcesses.name(of: current))] + apps
    }
}
