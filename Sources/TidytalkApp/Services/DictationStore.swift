import Foundation
import Observation
import TidytalkCore

/// 说话记录：每次说话输入、语音改写、快捷短语的结果。
///
/// 打开"保存说话记录"时存在 `~/Library/Application Support/Tidytalk/Dictations/dictations.json`
/// （只有当前用户能读写），超过保留天数的自动删除；关闭时只放在内存里（最多 20 条），退出即清空。
/// 只存文字（整理后的结果和识别原文），不存录音，也不记粘贴到了哪个应用。
@MainActor
@Observable
final class DictationStore {
    /// 最新的在前。
    private(set) var entries: [HistoryEntry] = []
    let root: URL
    /// 是否写进磁盘
    private(set) var saving: Bool
    /// 保留几天，0 表示一直保留
    private(set) var retentionDays: Int

    /// 不保存时内存里最多留几条
    static let memoryLimit = 20

    init(root: URL = DictationStore.defaultRoot, saving: Bool, retentionDays: Int) {
        self.root = root
        self.saving = saving
        self.retentionDays = retentionDays
        if saving {
            load()
            prune()
        }
    }

    nonisolated static var defaultRoot: URL {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        // 开发用：`--config <文件>` 时记录放在那份配置旁边，截图时不碰真实的说话记录
        if CommandLine.arguments.contains("--config") {
            return ConfigStore.defaultFileURL.deletingPathExtension().appendingPathExtension("dictations")
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Tidytalk/Dictations", directoryHint: .isDirectory)
    }

    private var fileURL: URL { root.appending(path: "dictations.json") }

    func entry(_ id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if saving {
            prune(saving: false)
        } else if entries.count > Self.memoryLimit {
            entries.removeLast(entries.count - Self.memoryLimit)
        }
        persist()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        if saving {
            persist()
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 改了"保存说话记录"或保留天数。关掉保存时删掉磁盘上的文件，这次打开期间的记录还在内存里；
    /// 重新打开时把内存里的记录写进去。
    func configure(saving: Bool, retentionDays: Int) {
        let wasSaving = self.saving
        self.saving = saving
        self.retentionDays = retentionDays
        if saving && !wasSaving {
            persist()
        } else if !saving && wasSaving {
            try? FileManager.default.removeItem(at: fileURL)
            if entries.count > Self.memoryLimit { entries.removeLast(entries.count - Self.memoryLimit) }
        }
        if saving { prune() }
    }

    /// 删掉超过保留天数的记录。
    func prune(now: Date = Date()) {
        prune(now: now, saving: true)
    }

    private func prune(now: Date = Date(), saving persistChanges: Bool) {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        if persistChanges && entries.count != before { persist() }
    }

    /// 磁盘上占用的空间（字节）。
    var sizeOnDisk: Int64 {
        let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 文件坏了时不覆盖它（下次保存前先移到一边），免得丢掉全部记录
        guard let decoded = try? decoder.decode([HistoryEntry].self, from: data) else {
            let broken = root.appending(path: "dictations-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: broken)
            return
        }
        entries = decoded.sorted { $0.date > $1.date }
    }

    private func persist() {
        guard saving else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try ConfigStore.writePrivately(try encoder.encode(entries), to: fileURL)
        } catch {
            // 写不进去时（磁盘满）记录还在内存里，下次再试
        }
    }
}
