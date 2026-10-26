import Foundation

/// 一次文件或链接转写的记录，保存在本机。本机文件只记下原文件的位置（不复制）；
/// 链接下载的音频和封面图放在记录自己的目录里，可以单独删除音频、保留文字。
public struct Transcription: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case file, link
    }

    public enum State: String, Codable, Sendable {
        case transcribing, finished, failed
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var createdAt: Date
    public var state: State
    public var error: String?
    /// 中途停止，只有前面一部分文字
    public var isPartial: Bool
    /// 音频长度（秒），读取音频后才知道
    public var duration: TimeInterval?
    /// 识别用的模型名
    public var model: String
    /// 本机文件的完整路径
    public var sourcePath: String?
    /// 链接的网址、上传者
    public var link: String?
    public var uploader: String?
    /// 记录目录里的音频和封面图的文件名；删除音频后为 nil
    public var audioFile: String?
    public var thumbnailFile: String?
    /// 音频文件大小（字节）
    public var audioSize: Int64?
    public var segments: [TranscriptSegment]

    public init(id: UUID = UUID(), kind: Kind, title: String, createdAt: Date = Date(), state: State = .transcribing,
                model: String, sourcePath: String? = nil, link: String? = nil, segments: [TranscriptSegment] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.state = state
        self.isPartial = false
        self.model = model
        self.sourcePath = sourcePath
        self.link = link
        self.segments = segments
    }

    /// 链接的网站，去掉 www.，例如 youtube.com、bilibili.com。
    public var host: String? {
        guard let link, let host = URL(string: link)?.host?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { return String(host.dropFirst(prefix.count)) }
        return host
    }

    /// 文件类型，例如 MP3、MOV（本机文件看原文件，链接看下载的音频）。
    public var fileType: String? {
        let name = kind == .file ? sourcePath : audioFile
        guard let ext = name.map({ ($0 as NSString).pathExtension }), !ext.isEmpty else { return nil }
        return ext.uppercased()
    }

    /// 原文件是不是视频（卡片上用不同的图标）。
    public var isVideo: Bool {
        guard let type = fileType?.lowercased() else { return false }
        return ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(type)
    }

    /// 开头几句话，卡片上预览用。
    public var preview: String {
        segments.prefix(3).map(\.text).joined(separator: " ")
    }

    public var text: String {
        TranscriptExport.render(segments, as: .text)
    }

    /// 改一段的文字；改成空白时不改（删除整段用不着，转写的时间轴要保持完整）。
    public mutating func updateText(of id: Int, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].text = trimmed
    }

    /// 导出、另存为时的默认文件名：去掉文件名里不能用的字符，标题是网址时用"转写结果"。
    public var exportName: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix("http://") || name.hasPrefix("https://") {
            return String(localized: "转写结果")
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
