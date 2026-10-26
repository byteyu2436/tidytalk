import Foundation

/// 会议总结的提示词、长会议的分块，以及结果校验。
///
/// 会议记录很长时（Apple 智能只有约 4K token 的上下文），先把每一块整理成要点，再把各块的要点合成一份总结。
public enum MeetingSummaryPrompt {
    /// 每块最多多少个字符（按会议记录的行累积，不会从一句话中间切开）。
    public enum ChunkSize {
        /// Apple 智能：上下文小，还要留出提示词和输出的位置
        public static let appleIntelligence = 1500
        /// 云端或本机大模型
        public static let standard = 20_000
    }

    static let rules = """
    规则：
    1. 只根据会议记录写，不要编造记录里没有的人名、数字、日期和结论；记录里不确定的地方照实写"未明确"。
    2. 用会议里主要使用的语言写；小节标题也用这种语言。
    3. 会议记录由语音识别得到，可能有错别字和口语，按意思理解，不要照抄口误。
    4. 标注了"（同时）"的几行是几个人同时在说，文字混在一起，只提取能确定的内容。
    5. 输出 Markdown，不要用代码块包裹，不要输出开场白或解释。
    """

    public static let systemPrompt = """
    你是会议纪要助手。用户消息里 <transcript> 标签中是一场会议的记录，每行是"[时间] 说话人：内容"。请写一份会议总结，包含以下小节（没有内容的小节省略）：

    ## 概要
    两三句话说明这场会议讨论了什么、结论是什么。
    ## 讨论要点
    按话题列出要点，注明是谁提出的观点。
    ## 决定
    会上确定下来的事项。
    ## 待办
    "- [ ] 负责人：事项（截止时间）"，记录里没说负责人或截止时间就省略那一部分。
    ## 待定问题
    还没有结论、需要后续跟进的问题。

    \(rules)
    """

    /// 长会议分块时，先对每一块做的整理。
    static let partialPrompt = """
    你是会议纪要助手。用户消息里 <transcript> 标签中是一场长会议的其中一段记录（第 {index} 段，共 {total} 段），每行是"[时间] 说话人：内容"。\
    请把这一段整理成详细的笔记，按"讨论要点 / 决定 / 待办 / 待定问题"分类列出，保留说话人、数字和时间，供之后合成整场会议的总结。

    \(rules)
    """

    /// 把各段笔记合成整场会议的总结。
    static let mergePrompt = """
    你是会议纪要助手。用户消息里 <notes> 标签中是一场长会议按顺序分段整理出的笔记。请把它们合成一份完整的会议总结，\
    去掉重复的内容，前后矛盾时以后面的为准。总结包含以下小节（没有内容的小节省略）：概要、讨论要点、决定、待办（"- [ ] 负责人：事项"）、待定问题，\
    每节用二级标题。

    \(rules)
    """

    /// 会议记录的文字形式：每行"[1:02] 张三：内容"，几个人同时说话时"[1:02] 张三、李四（同时）：内容"。
    public static func transcriptLines(_ meeting: Meeting) -> [String] {
        meeting.segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }.map { segment in
            let overlap = segment.isOverlap ? String(localized: "（同时）") : ""
            return "[\(TranscriptExport.clock(segment.start))] \(meeting.speakerNames(of: segment))\(overlap)：\(segment.text)"
        }
    }

    /// 按行累积成块，每块不超过 `limit` 个字符；单独一行超过上限时截成几块。
    public static func chunks(_ lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        func flush() {
            if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
            current = []
            size = 0
        }
        for line in lines {
            var rest = Substring(line)
            while rest.count > limit {
                flush()
                chunks.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            if size + rest.count + 1 > limit { flush() }
            current.append(String(rest))
            size += rest.count + 1
        }
        flush()
        return chunks
    }

    /// 一块就放得下时，直接生成总结。
    public static func messages(transcript: String) -> [TranscriptCleanup.Message] {
        [.init(role: .system, content: systemPrompt),
         .init(role: .user, content: "<transcript>\n\(escape(transcript))\n</transcript>")]
    }

    /// 长会议的第 `index` 块（从 1 开始）。
    public static func partialMessages(chunk: String, index: Int, total: Int) -> [TranscriptCleanup.Message] {
        let system = partialPrompt.replacingOccurrences(of: "{index}", with: "\(index)")
            .replacingOccurrences(of: "{total}", with: "\(total)")
        return [.init(role: .system, content: system),
                .init(role: .user, content: "<transcript>\n\(escape(chunk))\n</transcript>")]
    }

    public static func mergeMessages(notes: [String]) -> [TranscriptCleanup.Message] {
        let body = notes.enumerated().map { "### \($0.offset + 1)\n\(escape($0.element))" }.joined(separator: "\n\n")
        return [.init(role: .system, content: mergePrompt), .init(role: .user, content: "<notes>\n\(body)\n</notes>")]
    }

    /// 合并时各段笔记加起来超过一块的上限，就先两两合并，直到放得下。
    public static func mergeRounds(_ notes: [String], limit: Int) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for note in notes {
            if !current.isEmpty, size + note.count > limit {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(note)
            size += note.count
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// 会议记录来自别人的发言，里面的标签不能被当成指令。
    static func escape(_ text: String) -> String {
        var result = text
        for tag in ["transcript", "notes"] {
            for form in ["<\(tag)>", "</\(tag)>"] {
                result = result.replacingOccurrences(of: form, with: form.replacingOccurrences(of: "<", with: "＜")
                    .replacingOccurrences(of: ">", with: "＞"), options: .caseInsensitive)
            }
        }
        return result
    }

    /// 去掉代码块包裹和多余的标签；空结果返回 nil。
    public static func validate(_ output: String) -> String? {
        var text = TranscriptCleanup.sanitize(output)
        for tag in ["<transcript>", "</transcript>", "<notes>", "</notes>"] {
            text = text.replacingOccurrences(of: tag, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptCleanup.hasContent(text) ? text : nil
    }
}
