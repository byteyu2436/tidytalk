import Foundation

/// 会后处理的纯逻辑：把说话人分离的结果变成要识别的片段，标出几个人同时说话的地方，去掉扬声器漏进麦克风的回声。
public enum MeetingAlignment {
    /// 说话人分离给出的一段：某个说话人从 start 到 end 在说话。不同说话人的段可能在时间上重叠。
    public struct Turn: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var speaker: Int

        public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    /// 要送去识别的一段音频，以及这段时间里在说话的人（多于一个表示同时说话）。
    public struct Unit: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var speakers: [Int]

        public init(start: TimeInterval, end: TimeInterval, speakers: [Int]) {
            self.start = start
            self.end = end
            self.speakers = speakers
        }
    }

    /// 同时说话短于这个秒数时不单独标出来（附和一声"嗯"、抢话的一瞬间），算进前后说得更久的人。
    public static let minimumOverlap: TimeInterval = 1.0
    /// 同一个人两段之间停顿短于这个秒数时合成一段识别，句子不会被切碎。
    public static let mergeGap: TimeInterval = 1.2

    /// 按说话人的变化切成识别片段：每段里在说话的人不变；同一个人连着说的合并，合并后不超过 `maxSeconds`。
    public static func units(from turns: [Turn], maxSeconds: Double) -> [Unit] {
        let turns = turns.filter { $0.end > $0.start }
        guard !turns.isEmpty else { return [] }

        // 1. 按所有起止点把时间轴切成小段，每小段里在说话的人固定
        let points = Array(Set(turns.flatMap { [$0.start, $0.end] })).sorted()
        var pieces: [Unit] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let active = turns.filter { $0.start < b && $0.end > a }.map(\.speaker)
            guard !active.isEmpty else { continue }
            pieces.append(Unit(start: a, end: b, speakers: Array(Set(active)).sorted()))
        }

        // 2. 很短的同时说话算进相邻的单人段（取前后时间更长的一边里的人）
        for i in pieces.indices where pieces[i].speakers.count > 1 && pieces[i].end - pieces[i].start < minimumOverlap {
            let before = i > 0 ? pieces[i - 1] : nil
            let after = i + 1 < pieces.count ? pieces[i + 1] : nil
            let neighbor = [before, after].compactMap { $0 }
                .filter { $0.speakers.count == 1 && pieces[i].speakers.contains($0.speakers[0]) }
                .max { ($0.end - $0.start) < ($1.end - $1.start) }
            if let neighbor { pieces[i].speakers = neighbor.speakers }
        }

        // 3. 相邻、说话人相同、停顿不长的合并；同一个人的段不超过 maxSeconds
        var units: [Unit] = []
        for piece in pieces {
            if var last = units.last, last.speakers == piece.speakers, piece.start - last.end < mergeGap,
               piece.end - last.start <= maxSeconds {
                last.end = piece.end
                units[units.count - 1] = last
            } else {
                units.append(piece)
            }
        }
        // 一个人一口气说得比 maxSeconds 还久的段不在这里切：按时间平均切会切在字中间，
        // 由调用方在音频最安静的地方切开（AudioMath.chunkRanges）
        return units
    }

    /// 补回来的空档至少要这么长：太短的多半只是两段之间的换气、尾音。
    public static let minimumMissed: TimeInterval = 1.0

    /// 说话人分离漏掉的话：语音检测找到的每一句里，没有被任何识别片段覆盖、长于 `minimumMissed` 的空档，
    /// 补成一个片段，算在时间上最近的那个片段的说话人名下。保证有人说过的话不会因为分离没认出来而丢掉。
    /// - Parameter speech: 语音检测找到的句子（起止秒）。
    public static func uncovered(_ speech: [(start: TimeInterval, end: TimeInterval)], by units: [Unit]) -> [Unit] {
        let covered = units.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var result: [Unit] = []
        for sentence in speech where sentence.end > sentence.start {
            // 从这一句里依次减掉被覆盖的部分
            var cursor = sentence.start
            var gaps: [(TimeInterval, TimeInterval)] = []
            for (start, end) in covered where end > cursor && start < sentence.end {
                if start > cursor { gaps.append((cursor, min(start, sentence.end))) }
                cursor = max(cursor, end)
            }
            if cursor < sentence.end { gaps.append((cursor, sentence.end)) }
            for (start, end) in gaps where end - start >= minimumMissed {
                let gap = (start: start, end: end)
                let nearest = units.min { distance($0, gap) < distance($1, gap) }
                result.append(Unit(start: start, end: end, speakers: nearest.map { [$0.speakers[0]] } ?? []))
            }
        }
        return result
    }

    /// 把漏掉的话补进识别片段：紧挨着某个片段的空档（一句话的尾音、开头被分离切掉了）直接并进那个片段一起识别，
    /// 单独识别一秒多的尾音容易被识别成"Yeah.""I."这样的杂词；不挨着任何片段的才单独成段。
    public static func filling(_ units: [Unit], with speech: [(start: TimeInterval, end: TimeInterval)]) -> [Unit] {
        var result = units.sorted { $0.start < $1.start }
        let touching: TimeInterval = 0.05
        for gap in uncovered(speech, by: units) {
            if let i = result.firstIndex(where: { abs($0.end - gap.start) < touching && $0.speakers.count == 1 }) {
                result[i].end = max(result[i].end, gap.end)
            } else if let i = result.firstIndex(where: { abs($0.start - gap.end) < touching && $0.speakers.count == 1 }) {
                result[i].start = min(result[i].start, gap.start)
            } else {
                result.append(gap)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func distance(_ unit: Unit, _ sentence: (start: TimeInterval, end: TimeInterval)) -> TimeInterval {
        if unit.end < sentence.start { return sentence.start - unit.end }
        if unit.start > sentence.end { return unit.start - sentence.end }
        return 0
    }

    /// 麦克风一路分出来的人：说话总时长最多的是"我"，其余按第一次说话的先后编成"现场 1、2"。
    /// 返回说话人编号到会议说话人 id 的对应，以及需要加进会议的说话人。
    public static func microphoneSpeakers(_ turns: [Turn]) -> (ids: [Int: String], speakers: [MeetingSpeaker]) {
        var total: [Int: TimeInterval] = [:]
        var first: [Int: TimeInterval] = [:]
        for turn in turns {
            total[turn.speaker, default: 0] += turn.end - turn.start
            first[turn.speaker] = min(first[turn.speaker] ?? .infinity, turn.start)
        }
        guard let me = total.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key
        else { return ([:], [.me]) }
        var ids = [me: MeetingSpeaker.me.id]
        var speakers = [MeetingSpeaker.me]
        for (n, speaker) in first.keys.filter({ $0 != me }).sorted(by: { first[$0]! < first[$1]! }).enumerated() {
            let room = MeetingSpeaker(id: "room-\(n + 1)", role: .room(n + 1))
            ids[speaker] = room.id
            speakers.append(room)
        }
        return (ids, speakers)
    }

    /// 电脑声音一路分出来的人，按第一次说话的先后编成"说话人 1、2"。
    public static func remoteSpeakers(_ turns: [Turn]) -> (ids: [Int: String], speakers: [MeetingSpeaker]) {
        var first: [Int: TimeInterval] = [:]
        for turn in turns { first[turn.speaker] = min(first[turn.speaker] ?? .infinity, turn.start) }
        var ids: [Int: String] = [:]
        var speakers: [MeetingSpeaker] = []
        for (n, speaker) in first.keys.sorted(by: { first[$0]! < first[$1]! }).enumerated() {
            let remote = MeetingSpeaker(id: "remote-\(n + 1)", role: .remote(n + 1))
            ids[speaker] = remote.id
            speakers.append(remote)
        }
        return (ids, speakers)
    }

    // MARK: - 回声

    /// 时间重叠占麦克风这段的比例达到这个值，才可能是回声。
    static let echoTimeOverlap = 0.5
    /// 文字相同的比例达到这个值，判定是回声。
    static let echoTextSimilarity = 0.6
    /// 扬声器到麦克风、两路采集之间的时间差，比较时放宽这么多秒。
    static let echoTolerance: TimeInterval = 1.0

    /// 去掉麦克风里的回声：不戴耳机时，扬声器放出的对方的话会被麦克风再录一遍，识别成"我"说的。
    /// 判断依据：和电脑声音里同一时间的一段话内容几乎一样。自己和对方同时说的不同内容不受影响。
    public static func removingEcho(from segments: [MeetingSegment]) -> [MeetingSegment] {
        let system = segments.filter { $0.source == .system }
        return segments.filter { segment in
            guard segment.source == .microphone else { return true }
            return !isEcho(segment, of: system)
        }
    }

    static func isEcho(_ mic: MeetingSegment, of system: [MeetingSegment]) -> Bool {
        let micTokens = TranscriptCleanup.tokens(mic.text)
        guard !micTokens.isEmpty, mic.duration > 0 else { return false }
        // 和时间上挨着的几段电脑声音合起来比：麦克风的一句可能横跨对方的两句
        let nearby = system.filter {
            $0.start < mic.end + echoTolerance && $0.end > mic.start - echoTolerance
        }
        guard !nearby.isEmpty else { return false }
        let covered = nearby.reduce(0.0) { sum, s in
            sum + max(0, min(s.end + echoTolerance, mic.end) - max(s.start - echoTolerance, mic.start))
        }
        guard covered / mic.duration >= echoTimeOverlap else { return false }
        let known = Set(TranscriptCleanup.tokens(nearby.map(\.text).joined()))
        let shared = Double(micTokens.filter(known.contains).count) / Double(micTokens.count)
        return shared >= echoTextSimilarity
    }
}
