import Foundation
import Observation
import TidytalkCore

/// 转写记录保存在本机：`~/Library/Application Support/Tidytalk/Transcriptions/<id>/`，里面是
/// `transcription.json`（文字和来源），以及链接下载的音频和封面图。文件都只有当前用户能读写（0600）。
@MainActor
@Observable
final class TranscriptionStore {
    /// 从新到旧。
    private(set) var items: [Transcription] = []
    let root: URL

    init(root: URL = TranscriptionStore.defaultRoot) {
        self.root = root
        reload()
    }

    nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Tidytalk/Transcriptions", directoryHint: .isDirectory)
    }

    func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func jsonURL(_ id: UUID) -> URL {
        directory(for: id).appending(path: "transcription.json")
    }

    func item(_ id: UUID) -> Transcription? {
        items.first { $0.id == id }
    }

    func items(of kind: Transcription.Kind) -> [Transcription] {
        items.filter { $0.kind == kind }
    }

    /// 能播放的音频：链接是下载到记录目录里的文件，本机文件是原文件（被移走或删掉后为 nil）。
    func audioURL(_ item: Transcription) -> URL? {
        let url: URL? = switch item.kind {
        case .link: item.audioFile.map { directory(for: item.id).appending(path: $0) }
        case .file: item.sourcePath.map { URL(fileURLWithPath: $0) }
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func thumbnailURL(_ item: Transcription) -> URL? {
        item.thumbnailFile.map { directory(for: item.id).appending(path: $0) }
    }

    /// 重新读取全部记录。格式不对的文件跳过（不删除，免得丢数据）；
    /// 上次退出时还在转写的（应用中途退出），标成没有转写完。
    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "transcription.json")),
                  var item = try? decoder.decode(Transcription.self, from: data)
            else { return nil }
            if item.state == .transcribing {
                item.state = item.segments.isEmpty ? .failed : .finished
                item.isPartial = !item.segments.isEmpty
                if item.segments.isEmpty { item.error = String(localized: "没有转写完，Tidytalk 中途退出了") }
            }
            return item
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// 新建记录的目录（只有当前用户能进入）。
    func create(_ item: Transcription) throws {
        try FileManager.default.createDirectory(at: directory(for: item.id), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try save(item)
    }

    func save(_ item: Transcription) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try ConfigStore.writePrivately(try encoder.encode(item), to: jsonURL(item.id))
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.createdAt > $1.createdAt }
        }
    }

    /// 修改一条记录并保存（改标题、改文字、转写完成……）。
    func update(_ id: UUID, _ change: (inout Transcription) -> Void) {
        guard var item = item(id) else { return }
        change(&item)
        try? save(item)
    }

    /// 删除整条记录（文字、下载的音频和封面图）。本机的原文件不动。
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        items.removeAll { $0.id == id }
    }

    /// 只删链接下载的音频，保留文字和封面图。
    func deleteAudio(_ id: UUID) {
        guard let item = item(id), item.kind == .link, let file = item.audioFile else { return }
        try? FileManager.default.removeItem(at: directory(for: id).appending(path: file))
        update(id) {
            $0.audioFile = nil
            $0.audioSize = nil
        }
    }

    /// 所有记录占用的磁盘空间（主要是下载的音频）。
    func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
