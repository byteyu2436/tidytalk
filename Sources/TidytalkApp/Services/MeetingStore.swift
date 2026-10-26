import Foundation
import Observation
import TidytalkCore

/// 会议记录保存在本机：`~/Library/Application Support/Tidytalk/Meetings/<id>/`，里面是
/// `meeting.json`（文字、说话人、总结），以及两路录音（录音时是 `mic.pcm`/`system.pcm`，处理完转成 `.m4a`）。
/// 文件都只有当前用户能读写（0600）。
@MainActor
@Observable
final class MeetingStore {
    /// 按开始时间从新到旧。
    private(set) var meetings: [Meeting] = []
    let root: URL

    init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
        reload()
    }

    nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Tidytalk/Meetings", directoryHint: .isDirectory)
    }

    func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func pcmURL(_ id: UUID, _ source: MeetingSource) -> URL {
        directory(for: id).appending(path: "\(Self.fileStem(source)).pcm")
    }

    func audioURL(_ id: UUID, _ source: MeetingSource) -> URL {
        directory(for: id).appending(path: "\(Self.fileStem(source)).m4a")
    }

    private nonisolated static func fileStem(_ source: MeetingSource) -> String {
        source == .microphone ? "mic" : "system"
    }

    private func jsonURL(_ id: UUID) -> URL {
        directory(for: id).appending(path: "meeting.json")
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// 重新读取全部会议。格式不对的文件跳过（不删除，免得丢数据）。
    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meetings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// 新建会议的目录（只有当前用户能进入），返回放录音的位置。
    func create(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try save(meeting)
    }

    func save(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try ConfigStore.writePrivately(try encoder.encode(meeting), to: jsonURL(meeting.id))
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
    }

    /// 修改一场会议并保存（改名、改标题、加总结……）。
    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        try? save(meeting)
    }

    /// 删除整场会议（文字和录音）。
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        meetings.removeAll { $0.id == id }
    }

    /// 只删录音，保留文字和总结。
    func deleteRecording(_ id: UUID) {
        for source in MeetingSource.allCases {
            try? FileManager.default.removeItem(at: audioURL(id, source))
            try? FileManager.default.removeItem(at: pcmURL(id, source))
        }
        update(id) { $0.hasRecording = false }
    }

    /// 所有会议占用的磁盘空间。
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
