import AppKit
import SwiftUI
import TidytalkCore
import UniformTypeIdentifiers

/// 「转写」（设计稿「主窗口 · 转写」）：上面拖文件、粘贴链接，下面是转写记录，点一条进转写详情。
/// 一次只转写一个；正在转写时上面变灰，写明在等哪一个。
struct TranscribeView: View {
    let transcriber: TranscribeController
    let navigation: MainNavigation

    @ViewState private var link = ""
    @ViewState private var drop = FileDropModel()
    @ViewState private var deleting: Transcription?
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PageHeader { PageTitle(title: String(localized: "转写")) }
            PageBody {
                PageHeading(title: String(localized: "转写"),
                            message: String(localized: "把音频、视频文件或视频链接转成文字。声音在这台 Mac 上识别，链接只下载音频。"))
                input
                records
            }
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(model: drop, enabled: !transcriber.isBusy) {
                [transcriber, navigation] url in
                Self.transcribe(file: url, with: transcriber, navigation: navigation)
            })
        }
        .onChange(of: navigation.linkFieldRequest) { linkFocused = true }
        .onAppear { if navigation.linkFieldRequest > 0 { linkFocused = true } }
        .confirmationDialog("删除这条转写？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("删除", role: .destructive) { transcriber.store.delete(item.id) }
        } message: { item in
            Text(TranscribeFormat.deleteMessage(item))
        }
    }

    // MARK: - 拖文件、粘贴链接

    private var busy: Bool { transcriber.isBusy }
    private var targeted: Bool { drop.hovering && !busy }

    private var input: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropArea
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("粘贴视频链接，例如 YouTube 或 B 站的视频页面", text: $link)
                        .textFieldStyle(.plain)
                        .focused($linkFocused)
                        .onSubmit(submitLink)
                        .onChange(of: link) { if transcriber.failure?.kind == .link { transcriber.clearFailure() } }
                        .linearField(focused: linkFocused, error: transcriber.failure?.kind == .link)
                    // 设计稿里一直是黑色；没填链接时点了会在下面提示
                    IconButton("arrow.right", help: "转写这个链接（回车）", size: 36, prominent: true, action: submitLink)
                }
                if let failure = transcriber.failure {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .medium))
                        Text(failure.message).font(Theme.caption)
                    }
                    .foregroundStyle(Theme.danger)
                } else {
                    Text("第一次转写链接时，会先下载开源工具 yt-dlp。只下载音频和封面，不下载视频。")
                        .font(Theme.small)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .opacity(busy ? 0.55 : 1)
            .disabled(busy)
        }
        .padding(20)
        .cardStyle()
    }

    private var dropArea: some View {
        HStack(spacing: 16) {
            Image(systemName: targeted ? "arrow.down.to.line" : "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(targeted ? .white : Theme.Tint.speech)
                .frame(width: 40, height: 40)
                .background(targeted ? Theme.Tint.speech : Theme.panel,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if !targeted { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(dropTitle).font(Theme.heading).foregroundStyle(Theme.text).lineLimit(1)
                Text(dropMessage).font(Theme.caption).foregroundStyle(Theme.secondaryText).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !targeted {
                IconButton("folder", help: "选择文件（⌘O）", outlined: true, action: chooseFile)
            }
        }
        .padding(16)
        .background(targeted ? Theme.Tint.speech.opacity(0.07) : Theme.subtle,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(targeted ? Theme.Tint.speech : Theme.border, lineWidth: targeted ? 2 : 1))
        .opacity(busy ? 0.55 : 1)
        .disabled(busy)
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var dropTitle: String {
        if targeted { return String(localized: "松开就开始转写") }
        if busy { return String(localized: "正在转写“\(transcriber.title)”") }
        return String(localized: "把音频或视频文件拖到这里")
    }

    private var dropMessage: String {
        if targeted {
            return [drop.name, drop.size.map(TranscribeFormat.size)].compactMap { $0 }.joined(separator: " · ")
        }
        if busy { return String(localized: "一次转写一个，这个完成后就可以开始下一个。") }
        return String(localized: "MP3、M4A、WAV、MP4、MOV 这些常见格式都可以，也可以点右边的按钮选择文件。")
    }

    private func submitLink() {
        guard !busy else { return }
        transcriber.clearFailure()
        if let id = transcriber.transcribe(link: link) {
            link = ""
            navigation.openTranscription(id, from: .transcribe)
        }
    }

    private func transcribe(file url: URL) {
        Self.transcribe(file: url, with: transcriber, navigation: navigation)
    }

    private static func transcribe(file url: URL, with transcriber: TranscribeController, navigation: MainNavigation) {
        guard !transcriber.isBusy else { return }
        transcriber.clearFailure()
        if let id = transcriber.transcribe(file: url) { navigation.openTranscription(id, from: .transcribe) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(file: url)
    }

    // MARK: - 转写记录

    private var items: [Transcription] {
        transcriber.store.items.sorted { $0.createdAt > $1.createdAt }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: Theme.titleGap) {
            GroupTitle(title: String(localized: "转写记录"), count: items.isEmpty ? nil : items.count) {
                if !items.isEmpty {
                    IconButton("arrow.right", help: "在资料库里看全部转写") {
                        navigation.show(.library)
                        navigation.libraryFilter = .transcriptions
                    }
                }
            }
            if items.isEmpty {
                EmptyState(symbol: "doc.text", tint: Theme.Tint.speech, title: String(localized: "还没有转写记录"),
                           message: String(localized: "转写好的文字会放在这里，也能在资料库里找到。"), fill: false)
                    .padding(.vertical, -12)
                    .cardStyle()
            } else {
                RowList(items) { item in
                    LibraryRow(item: .transcription(item), status: RowStatus.transcription(item, controller: transcriber,
                                                                                         showsFailure: false),
                               meta: TranscribeFormat.meta(item, controller: transcriber)) {
                        navigation.openTranscription(item.id, from: .transcribe)
                    } actions: {
                        if transcriber.current != item.id {
                            IconButton("trash", help: "删除", size: 28, tint: Theme.danger) { deleting = item }
                        }
                    }
                }
            }
        }
    }
}

/// 拖着文件经过“转写”页时：拖放区变成青色，写出文件名和大小。
@MainActor
@Observable
final class FileDropModel {
    var hovering = false
    var name: String?
    var size: Int64?
}

private struct FileDropDelegate: DropDelegate {
    let model: FileDropModel
    let enabled: Bool
    let onDrop: @MainActor @Sendable (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        model.hovering = true
        model.name = nil
        model.size = nil
        load(info) { [model] url in
            model.name = url.lastPathComponent
            model.size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
    }

    func dropExited(info: DropInfo) { model.hovering = false }

    func performDrop(info: DropInfo) -> Bool {
        model.hovering = false
        guard enabled else { return false }
        load(info) { url in onDrop(url) }
        return true
    }

    private func load(_ info: DropInfo, then handle: @escaping @MainActor @Sendable (URL) -> Void) {
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in handle(url) }
        }
    }
}
