import AVFoundation
import SwiftUI
import TidytalkCore

/// 正在录的会议（设计稿「详情 · 开会中」）：标题和属性、两路声音的电平，下面是实时文字（“我”和“对方”两种颜色）。
/// 停止按钮只在侧边栏底部的卡片上（切到别的页面也能结束），这一页不放第二个。
struct MeetingLiveView: View {
    let meetings: MeetingController
    let navigation: MainNavigation

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                Breadcrumb(parent: navigation.section.title, title: String(localized: "正在记录")) {
                    navigation.closeRecord()
                }
            }
            if let meeting = meetings.current {
                PageBody(scrolls: false) {
                    head(meeting)
                    if let warning = meetings.warning {
                        let parts = warning.split(separator: "：", maxSplits: 1).map(String.init)
                        AlertBar(symbol: "exclamationmark.triangle", tint: Theme.Tint.progress, title: parts[0],
                                 message: parts.count > 1 ? parts[1] : nil) {
                            IconButton("arrow.up.right", help: "打开系统设置", outlined: true,
                                       action: Permissions.openSystemAudioSettings)
                        }
                    }
                    HStack(spacing: 12) {
                        SourceCard(name: String(localized: "我"), device: Self.microphoneName,
                                   color: SpeakerColors.color(for: MeetingSpeaker.me.id, in: meeting),
                                   level: meetings.levels[.microphone] ?? 0)
                        SourceCard(name: String(localized: "对方"), device: Self.systemSource(meetings),
                                   color: SpeakerColors.color(for: MeetingSpeaker.remoteAll.id, in: meeting),
                                   level: meetings.levels[.system] ?? 0)
                    }
                    if meeting.segments.isEmpty && meetings.queued.isEmpty {
                        EmptyState(symbol: "waveform", tint: Theme.Tint.recording, title: String(localized: "正在听"),
                                   message: String(localized: "开始说话后，文字会出现在这里。说完一句才显示，会后还会分出说话人、再精修一遍。"))
                            .padding(.bottom, 40)
                    } else {
                        TranscriptList(meeting: meeting, followLatest: true,
                                       recognizing: meetings.queued.sorted { $0.rawValue < $1.rawValue })
                            .frame(maxHeight: .infinity, alignment: .top)
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 11, weight: .medium))
                            Text("说完一句才显示。结束后会分出对方的说话人，再精修一遍文字。停止按钮在左下角。")
                        }
                        .font(Theme.small)
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private func head(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.title).font(Theme.title).tracking(Theme.titleTracking).foregroundStyle(Theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow(spacing: 8) {
                if meetings.phase == .finishing {
                    PropertyChip(symbol: "rays", text: String(localized: "正在识别最后几句…"), tint: Theme.Tint.progress)
                } else {
                    PropertyChip(symbol: "record.circle",
                                 text: String(localized: "正在记录 \(MeetingFormat.clock(meetings.elapsed))"),
                                 tint: Theme.Tint.recording)
                }
                PropertyChip(symbol: "calendar",
                             text: String(localized: "开始于 \(meeting.startedAt.formatted(date: .omitted, time: .shortened))"))
                PropertyChip(symbol: "lock", text: String(localized: "录音保存在这台 Mac 上"), tint: Theme.Tint.local)
            }
        }
    }

    /// 系统默认的麦克风名字（MacBook Pro 麦克风）
    private static var microphoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "麦克风")
    }

    /// 电脑的声音 · 全部应用 / 某个应用
    private static func systemSource(_ meetings: MeetingController) -> String {
        if meetings.levels.keys.contains(.system), meetings.warning != nil {
            return String(localized: "电脑的声音 · 没有声音")
        }
        let source = meetings.listenSourceName
        return String(localized: "电脑的声音 · \(source)")
    }
}

/// 一路声音：头像、名字和设备，右边是跳动的电平。
private struct SourceCard: View {
    let name: String
    let device: String
    let color: Color
    let level: Float

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 32, height: 32)
                .overlay { Text(verbatim: String(name.prefix(1))).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(device).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MeetingLevelMeter(level: level, color: color)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .cardStyle()
    }
}

/// 说完了、还在识别的一句：灰色的“正在识别……”。
struct RecognizingRow: View {
    let meeting: Meeting
    let source: MeetingSource

    var body: some View {
        let speaker = source == .microphone ? MeetingSpeaker.me : MeetingSpeaker.remoteAll
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(speaker: speaker, color: SpeakerColors.color(for: speaker.id, in: meeting), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(speaker.name).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text("正在识别……").font(Theme.reading).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 一路声音的电平：8 根随音量跳动的竖条。
struct MeetingLevelMeter: View {
    let level: Float
    var color: Color = .green

    private static let bars = 8

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let lit = Float(index) / Float(Self.bars) < level
                Capsule()
                    .fill(lit ? color : Theme.subtle)
                    .frame(width: 3, height: 6 + CGFloat(index % 4) * 4)
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// 正在录音的红点，慢慢闪动。
struct RecordingDot: View {
    var size: CGFloat = 8
    @ViewState private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

enum MeetingFormat {
    /// 1:02:03 或 12:34
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "45 分钟"、"1 小时 5 分钟"、"不到 1 分钟"
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "不到 1 分钟") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? ""
    }

    /// 按天分组：今天、昨天、其他日期（"10月21日 星期二"），每组里从新到旧。
    static func groupedByDay(_ meetings: [Meeting]) -> [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var groups: [(title: String, meetings: [Meeting])] = []
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            let title: String
            if calendar.isDateInToday(meeting.startedAt) {
                title = String(localized: "今天")
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                title = String(localized: "昨天")
            } else {
                title = meeting.startedAt.formatted(.dateTime.month().day().weekday())
            }
            if groups.last?.title == title {
                groups[groups.count - 1].meetings.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        return groups
    }
}
