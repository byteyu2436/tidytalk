import AppKit
import SwiftUI
import TidytalkCore
import UniformTypeIdentifiers

/// 转写窗口：拖入音频、视频文件，或粘贴视频链接，得到带时间的文字，可以拷贝或导出。
struct TranscribeView: View {
    let controller: TranscribeController
    @ViewState private var link = ""
    @ViewState private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.segments.isEmpty && !controller.stage.isBusy {
                dropZone
                linkField
            } else {
                header
                results
            }
            footer
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("把音频或视频文件拖到这里").font(.title3.weight(.medium))
            Text("MP3、M4A、WAV、MP4、MOV 等，最长 3 小时").font(.callout).foregroundStyle(.secondary)
            Button("选择文件…", action: chooseFile)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .background(targeted ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            controller.transcribe(file: url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("或者粘贴视频链接（YouTube、B 站等）", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.transcribe(link: link) }
                Button("转写") { controller.transcribe(link: link) }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(YTDLP.isInstalled
                 ? String(localized: "只下载链接里的音频，转写完就删除。仅限你有权使用的内容。")
                 : String(localized: "第一次转写链接时，会先从 GitHub 下载开源的下载工具 yt-dlp（约 35 MB）。仅限你有权使用的内容。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(controller.title.isEmpty ? String(localized: "转写结果") : controller.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if controller.stage.isBusy {
                Button("停止") { controller.cancel() }
            } else {
                Button("拷贝全文") { controller.copyAll() }
                Menu("导出") {
                    ForEach(TranscriptExport.Format.allCases, id: \.self) { format in
                        Button(format.title) { controller.export(as: format) }
                    }
                }
                .fixedSize()
                Button("新的转写") {
                    link = ""
                    controller.clear()
                }
            }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(TranscriptExport.clock(segment.start))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            Text(segment.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(segment.id)
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .onChange(of: controller.segments.count) {
                // 识别过程中跟着最新的一句往下滚
                if controller.stage.isBusy, let last = controller.segments.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch controller.stage {
            case .idle, .finished:
                // 模型名前后的空格由排版规则补上
                Label(Typography.format(String(localized: "在这台 Mac 上识别，使用\(model)模型。")), systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            case .installingTool:
                ProgressView().controlSize(.small)
                Text("正在下载 yt-dlp…").foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 160)
                Text("正在下载音频 \(Int(fraction * 100))%").foregroundStyle(.secondary)
            case .decoding(let fraction):
                ProgressView(value: fraction).frame(width: 160)
                Text("正在读取音频…").foregroundStyle(.secondary)
            case .recognizing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("正在识别 \(String(done))/\(String(total))").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                if controller.segments.isEmpty {
                    Button("重试") { controller.clear() }
                }
            }
            Spacer()
        }
        .font(.callout)
    }

    private var model: String { controller.modelTitle }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.transcribe(file: url)
    }
}

enum TranscribeWindow {
    @MainActor
    static func make(controller: TranscribeController) -> NSWindow {
        let window = FocusFriendlyWindow(contentViewController: NSHostingController(rootView: TranscribeView(controller: controller)))
        window.title = String(localized: "转写文件或链接")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
