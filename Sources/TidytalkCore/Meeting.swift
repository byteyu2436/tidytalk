import Foundation

/// 一段话来自哪一路音频：自己的麦克风，还是电脑里播放的声音（会议里的其他人）。
public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case system
}

/// 会议里的一个说话人。默认名字按角色生成（"我""对方""说话人 2"），用户改过名字时用 `customName`。
public struct MeetingSpeaker: Codable, Hashable, Sendable, Identifiable {
    public enum Role: Codable, Hashable, Sendable {
        /// 自己（麦克风里说话最多的人）
        case me
        /// 和自己在同一个房间、共用麦克风的人，从 1 开始编号
        case room(Int)
        /// 会议另一端的人（电脑声音里分出来的），从 1 开始编号
        case remote(Int)
        /// 电脑声音里的所有人：还没有分说话人（会议进行中，或者没有下载说话人模型）
        case remoteAll
    }

    public var id: String
    public var role: Role
    public var customName: String?

    public init(id: String, role: Role, customName: String? = nil) {
        self.id = id
        self.role = role
        self.customName = customName
    }

    public var source: MeetingSource {
        switch role {
        case .me, .room: .microphone
        case .remote, .remoteAll: .system
        }
    }

    public var name: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty { return customName }
        switch role {
        case .me: return String(localized: "我")
        case .room(let n): return String(localized: "现场 \(String(n))")
        case .remote(let n): return String(localized: "说话人 \(String(n))")
        case .remoteAll: return String(localized: "对方")
        }
    }

    public static let me = MeetingSpeaker(id: "me", role: .me)
    public static let remoteAll = MeetingSpeaker(id: "remote", role: .remoteAll)
}

/// 会议里的一段话。`speakerIDs` 多于一个时表示几个人同时在说，文字是混在一起识别出来的。
public struct MeetingSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var source: MeetingSource
    public var speakerIDs: [String]
    public var text: String

    public init(id: Int, start: TimeInterval, end: TimeInterval, source: MeetingSource, speakerIDs: [String],
                text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.source = source
        self.speakerIDs = speakerIDs
        self.text = text
    }

    public var isOverlap: Bool { speakerIDs.count > 1 }
    public var duration: TimeInterval { end - start }
}

/// AI 生成的会议总结。
public struct MeetingSummary: Codable, Hashable, Sendable {
    public var markdown: String
    public var createdAt: Date
    /// 用了哪个服务，例如"DeepSeek · deepseek-chat"、"Apple 智能"，显示在总结下面
    public var service: String
    /// 部分内容没有生成出来（回复被截断、某一段失败）
    public var isPartial: Bool

    public init(markdown: String, createdAt: Date, service: String, isPartial: Bool = false) {
        self.markdown = markdown
        self.createdAt = createdAt
        self.service = service
        self.isPartial = isPartial
    }
}

/// 一场会议：保存在本机，包括说话人、每段话和总结。录音文件和它放在同一个目录里（见 MeetingStore）。
public struct Meeting: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// 正在录
        case recording
        /// 录完了，正在分说话人、精修文字
        case processing
        case ready
        /// 会后处理失败，保留会议中识别的文字（见 `processingError`）
        case failed
    }

    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var state: State
    public var processingError: String?
    public var speakers: [MeetingSpeaker]
    public var segments: [MeetingSegment]
    public var summary: MeetingSummary?
    /// 录音文件还在（用户可以只删录音、保留文字）
    public var hasRecording: Bool

    public init(id: UUID = UUID(), title: String, startedAt: Date, duration: TimeInterval = 0,
                state: State = .recording, speakers: [MeetingSpeaker] = [.me, .remoteAll],
                segments: [MeetingSegment] = [], summary: MeetingSummary? = nil, hasRecording: Bool = true) {
        version = Self.currentVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.state = state
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.hasRecording = hasRecording
    }

    public func speaker(_ id: String) -> MeetingSpeaker? {
        speakers.first { $0.id == id }
    }

    /// 这段话是谁说的："张三"，几个人同时说时是"张三、李四"。
    public func speakerNames(of segment: MeetingSegment) -> String {
        segment.speakerIDs.compactMap { speaker($0)?.name }.joined(separator: String(localized: "、"))
    }

    /// 给说话人改名；空字符串恢复默认名字。
    public mutating func rename(speaker id: String, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[index].customName = trimmed.isEmpty ? nil : trimmed
    }

    /// 改一段话的文字（用户手动修正识别错误）。改成空白时不改。
    public mutating func updateText(of segmentID: Int, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].text = trimmed
    }

    /// 删掉一段话，返回删掉的那段（用来撤销）。
    @discardableResult
    public mutating func deleteSegment(_ segmentID: Int) -> MeetingSegment? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        return segments.remove(at: index)
    }

    /// 撤销删除：放回原来的位置（按开始时间）。
    public mutating func restore(_ segment: MeetingSegment) {
        guard !segments.contains(where: { $0.id == segment.id }) else { return }
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }

    /// 把一段话改给另一个人（说话人分错时）。几个人同时说话的段落改完就只算这一个人。
    public mutating func reassign(_ segmentID: Int, to speakerID: String) {
        guard speaker(speakerID) != nil, let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].speakerIDs = [speakerID]
    }

    /// 加一个新的说话人（改说话人时发现是没分出来的另一个人），返回它的 id。
    public mutating func addSpeaker(source: MeetingSource) -> String {
        let used = speakers.compactMap { speaker -> Int? in
            switch (speaker.role, source) {
            case (.remote(let n), .system), (.room(let n), .microphone): n
            default: nil
            }
        }
        let next = (used.max() ?? 0) + 1
        let new = source == .system ? MeetingSpeaker(id: "remote-\(next)", role: .remote(next))
            : MeetingSpeaker(id: "room-\(next)", role: .room(next))
        speakers.append(new)
        return new.id
    }

    /// 实际说过话的人（按第一次出现的顺序），列表和总结里用。
    public var activeSpeakers: [MeetingSpeaker] {
        var seen = Set<String>()
        var result: [MeetingSpeaker] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            for id in segment.speakerIDs where seen.insert(id).inserted {
                if let speaker = speaker(id) { result.append(speaker) }
            }
        }
        return result
    }

    /// 默认标题，例如"10月23日 14:05 的会议"。
    public static func defaultTitle(for date: Date) -> String {
        let format = Date.FormatStyle().month(.defaultDigits).day().hour().minute()
        return String(localized: "\(date.formatted(format)) 的会议")
    }
}

/// 把会议导出成 Markdown、SRT 字幕或纯文本，每段话前面带上说话人。
public enum MeetingExport {
    public static func render(_ meeting: Meeting, as format: TranscriptExport.Format) -> String {
        let segments = meeting.segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
        switch format {
        case .markdown:
            var lines = ["# \(meeting.title)", ""]
            for segment in segments {
                let overlap = segment.isOverlap ? String(localized: "（同时）") : ""
                lines.append("**\(meeting.speakerNames(of: segment))\(overlap)** \(TranscriptExport.clock(segment.start))  ")
                lines.append(segment.text)
                lines.append("")
            }
            if let summary = meeting.summary {
                lines += ["---", "", summary.markdown, ""]
            }
            return lines.joined(separator: "\n")
        case .srt:
            return segments.enumerated().map { index, segment in
                "\(index + 1)\n\(TranscriptExport.srtTime(segment.start)) --> \(TranscriptExport.srtTime(segment.end))\n"
                    + "\(meeting.speakerNames(of: segment))：\(segment.text)\n"
            }.joined(separator: "\n")
        case .text:
            // 同一个人连着说的几段合成一段
            var paragraphs: [(names: String, texts: [String])] = []
            for segment in segments {
                let names = meeting.speakerNames(of: segment)
                if paragraphs.last?.names == names {
                    paragraphs[paragraphs.count - 1].texts.append(segment.text)
                } else {
                    paragraphs.append((names, [segment.text]))
                }
            }
            return paragraphs.map { "\($0.names)：\(Transcript.join($0.texts))" }.joined(separator: "\n\n") + "\n"
        }
    }
}
