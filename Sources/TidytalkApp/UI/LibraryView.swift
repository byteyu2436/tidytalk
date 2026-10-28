import AppKit
import SwiftUI
import TidytalkCore

/// 资料库里的一条：说话记录、会议或转写。
enum LibraryItem: Identifiable {
    case dictation(HistoryEntry)
    case meeting(Meeting)
    case transcription(Transcription)

    var id: String {
        switch self {
        case .dictation(let entry): "d-\(entry.id)"
        case .meeting(let meeting): "m-\(meeting.id)"
        case .transcription(let item): "t-\(item.id)"
        }
    }

    var date: Date {
        switch self {
        case .dictation(let entry): entry.date
        case .meeting(let meeting): meeting.startedAt
        case .transcription(let item): item.createdAt
        }
    }

    var filter: MainNavigation.LibraryFilter {
        switch self {
        case .dictation: .dictation
        case .meeting: .meetings
        case .transcription: .transcriptions
        }
    }

    var title: String {
        switch self {
        case .dictation(let entry): entry.output.replacingOccurrences(of: "\n", with: " ")
        case .meeting(let meeting): meeting.title
        case .transcription(let item): TranscribeFormat.title(item)
        }
    }

    /// 类型和长度：说话 · 21 字、改写 · 要求：正式一点、会议 · 9 分钟 · 4 人、转写 · YouTube · 12 分钟。
    /// 不记粘贴到了哪个应用。
    var meta: String {
        switch self {
        case .dictation(let entry):
            switch entry.kind {
            case .dictation: return String(localized: "说话 · \(String(entry.output.count)) 字")
            case .rewrite: return String(localized: "改写 · 要求：\(entry.instruction)")
            case .snippet: return String(localized: "快捷短语 · \(entry.transcript)")
            }
        case .meeting(let meeting):
            var parts = [String(localized: "会议"), MeetingFormat.duration(meeting.duration)]
            if meeting.activeSpeakers.count > 1 { parts.append(String(localized: "\(String(meeting.activeSpeakers.count)) 人")) }
            return parts.joined(separator: " · ")
        case .transcription(let item):
            return ([String(localized: "转写")] + TranscribeFormat.source(item)).joined(separator: " · ")
        }
    }

    var symbol: (name: String, color: Color) {
        switch self {
        case .dictation(let entry): DictationKind.style(entry.kind)
        case .meeting: ("person.2", Theme.Tint.meeting)
        case .transcription(let item): TranscribeFormat.style(item)
        }
    }

    /// 搜索标题、说话人和文字。
    func matches(_ query: String) -> Bool {
        switch self {
        case .dictation(let entry):
            entry.output.localizedCaseInsensitiveContains(query) || entry.transcript.localizedCaseInsensitiveContains(query)
        case .meeting(let meeting):
            meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.speakers.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        case .transcription(let item):
            item.title.localizedCaseInsensitiveContains(query)
                || (item.uploader ?? "").localizedCaseInsensitiveContains(query)
                || item.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// 说话记录的三种：说话输入（红）、语音改写（紫）、快捷短语（橙）。
enum DictationKind {
    static func style(_ kind: HistoryEntry.Kind) -> (name: String, color: Color) {
        switch kind {
        case .dictation: ("mic", Theme.Tint.dictation)
        case .rewrite: ("sparkles", Theme.Tint.ai)
        case .snippet: ("text.quote", Theme.Tint.vocabulary)
        }
    }

    static func title(_ kind: HistoryEntry.Kind) -> String {
        switch kind {
        case .dictation: String(localized: "说话输入")
        case .rewrite: String(localized: "语音改写")
        case .snippet: String(localized: "快捷短语")
        }
    }
}

extension HistoryEntry {
    /// 语音改写时说的修改要求（`transcript` 存成“改写：要求”）。
    var instruction: String {
        let prefix = String(localized: "改写：")
        return transcript.hasPrefix(prefix) ? String(transcript.dropFirst(prefix.count)) : transcript
    }
}

/// 列表行右边的状态：正在记录、整理中 60%、整理失败、43%。颜色和侧边栏、首页一致。
struct RowStatus {
    /// nil 时右边照常写时间
    var text: String?
    var color: Color = Theme.secondaryText
    /// 换掉左边的类型图标（正在转写的黄色图标、失败的红色感叹号）
    var symbol: (name: String, color: Color)?

    @MainActor
    static func meeting(_ meeting: Meeting, processor: MeetingProcessor) -> RowStatus? {
        if let progress = processor.progress[meeting.id] {
            let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
            return RowStatus(text: String(localized: "整理中") + percent, color: Theme.Tint.progress)
        }
        switch meeting.state {
        case .recording: return RowStatus(text: String(localized: "正在记录"), color: Theme.Tint.recording)
        case .processing: return RowStatus(text: String(localized: "整理中"), color: Theme.Tint.progress)
        case .failed: return RowStatus(text: String(localized: "整理失败"), color: Theme.danger)
        case .ready: return nil
        }
    }

    @MainActor
    static func transcription(_ item: Transcription, controller: TranscribeController,
                              showsFailure: Bool = true) -> RowStatus? {
        if controller.current == item.id {
            let text = controller.stage.fraction.map { "\(Int($0 * 100))%" } ?? String(localized: "处理中")
            return RowStatus(text: text, color: Theme.Tint.progress, symbol: ("rays", Theme.Tint.progress))
        }
        if item.state == .failed {
            // 转写页的第二行已经写了原因，右边照常写时间
            return RowStatus(text: showsFailure ? String(localized: "转写失败") : nil, color: Theme.danger,
                             symbol: ("exclamationmark.circle", Theme.danger))
        }
        return nil
    }
}

/// 列表里的时间：今天 14:32、昨天、周一、10月20日。
enum RowTime {
    static func text(_ date: Date, timeOnly: Bool = false) -> String {
        let calendar = Calendar.current
        if timeOnly || calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month().day())
    }
}

/// 「资料库」：说话、会议、转写的结果放在一个列表里，按天分组，可以按类型筛选、搜索。点一条打开详情。
struct LibraryView: View {
    let model: AppModel
    let meetings: MeetingController
    let transcriber: TranscribeController
    let navigation: MainNavigation
    let actions: SettingsActions
    var onOpenSettings: (MainNavigation.SettingsPage) -> Void = { _ in }

    @ViewState private var deletingMeeting: Meeting?
    @ViewState private var deletingTranscription: Transcription?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(title: String(localized: "资料库"))
            } trailing: {
                SearchField(text: Binding(get: { navigation.search }, set: { navigation.search = $0 }),
                            prompt: "搜索资料库", focusRequest: navigation.searchRequest)
            }
            if items.isEmpty {
                PageBody(scrolls: false) {
                    top
                    empty.padding(.bottom, 60)
                }
            } else {
                PageBody {
                    top
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: Theme.titleGap) {
                            SectionHeader(title: group.title, count: group.items.count)
                            RowList(group.items) { item in row(item) }
                        }
                    }
                }
            }
        }
        .confirmationDialog("删除这场会议？", isPresented: Binding(get: { deletingMeeting != nil },
                                                           set: { if !$0 { deletingMeeting = nil } }),
                            presenting: deletingMeeting) { meeting in
            Button("删除会议和录音", role: .destructive) { meetings.store.delete(meeting.id) }
        } message: { meeting in
            Text("「\(meeting.title)」的文字、总结和录音都会删除，不能恢复。")
        }
        .confirmationDialog("删除这条转写？", isPresented: Binding(get: { deletingTranscription != nil },
                                                           set: { if !$0 { deletingTranscription = nil } }),
                            presenting: deletingTranscription) { item in
            Button("删除", role: .destructive) { transcriber.store.delete(item.id) }
        } message: { item in
            Text(TranscribeFormat.deleteMessage(item))
        }
    }

    /// 升级提示和筛选、排序那一行
    @ViewBuilder
    private var top: some View {
        if model.dictationNoticePending, navigation.libraryFilter != .meetings,
           navigation.libraryFilter != .transcriptions {
            AlertBar(symbol: "internaldrive", tint: Theme.Tint.local, title: String(localized: "说话记录现在会保存在这台 Mac 上"),
                     message: String(localized: "从这个版本起，说话输入的结果会保存 30 天，可以在资料库里搜索，不会上传。不想保存，可以在“设置 › 隐私与数据”里关掉。")) {
                IconButton("checkmark.shield", help: "打开隐私与数据", tint: Theme.Tint.local, outlined: true) {
                    onOpenSettings(.privacy)
                }
                IconButton("xmark", help: "知道了", action: model.dismissDictationNotice)
            }
        }
        HStack(spacing: 12) {
            LinearTabs(selection: Binding(get: { navigation.libraryFilter }, set: { navigation.libraryFilter = $0 }),
                       items: [.init(value: .all, title: String(localized: "全部"), count: count(.all)),
                               .init(value: .dictation, title: String(localized: "说话"), count: count(.dictation)),
                               .init(value: .meetings, title: String(localized: "会议"), count: count(.meetings)),
                               .init(value: .transcriptions, title: String(localized: "转写"), count: count(.transcriptions))])
            Spacer()
            SelectField(selection: Binding(get: { navigation.newestFirst }, set: { navigation.newestFirst = $0 }),
                        options: [(true, String(localized: "最新的在前")), (false, String(localized: "最早的在前"))])
        }
    }

    private var query: String { navigation.search.trimmingCharacters(in: .whitespaces) }

    private var allItems: [LibraryItem] {
        model.history.map(LibraryItem.dictation)
            + meetings.store.meetings.map(LibraryItem.meeting)
            + transcriber.store.items.map(LibraryItem.transcription)
    }

    /// 搜索后的全部条目（标签上的数字按搜索结果算）
    private var searched: [LibraryItem] {
        query.isEmpty ? allItems : allItems.filter { $0.matches(query) }
    }

    private var items: [LibraryItem] {
        searched
            .filter { navigation.libraryFilter == .all || $0.filter == navigation.libraryFilter }
            .sorted { navigation.newestFirst ? $0.date > $1.date : $0.date < $1.date }
    }

    private func count(_ filter: MainNavigation.LibraryFilter) -> Int {
        filter == .all ? searched.count : searched.filter { $0.filter == filter }.count
    }

    @ViewBuilder
    private var empty: some View {
        if !query.isEmpty {
            EmptyState(symbol: "magnifyingglass", tint: Theme.secondaryText, title: String(localized: "没有找到“\(query)”"),
                       message: String(localized: "会搜索标题、说话人和记录里的文字。换个词试试，或者清空搜索框。"))
        } else {
            switch navigation.libraryFilter {
            case .all:
                EmptyState(symbol: "books.vertical", tint: Theme.Tint.meeting, title: String(localized: "资料库还是空的"),
                           message: String(localized: "说话输入、会议记录和转写的结果都会放在这里。"))
            case .dictation where !model.dictations.saving:
                EmptyState(symbol: "internaldrive", tint: Theme.secondaryText, title: String(localized: "说话记录现在不保存"),
                           message: String(localized: "“设置 › 隐私与数据”里关掉了保存。这次打开期间说的话会显示在这里，退出后清空。"))
            case .dictation:
                EmptyState(symbol: "mic", tint: Theme.Tint.dictation, title: String(localized: "还没有说话记录"),
                           message: String(localized: "在任何输入框里按住 \(model.configStore.config.hotkey.symbol) 说话，结果会出现在这里。"))
            case .meetings:
                EmptyState(symbol: "person.2", tint: Theme.Tint.meeting, title: String(localized: "还没有会议记录"),
                           message: String(localized: "按 ⌃⌥M，或者在首页开始记录一场会议。"))
            case .transcriptions:
                EmptyState(symbol: "waveform", tint: Theme.Tint.speech, title: String(localized: "还没有转写"),
                           message: String(localized: "在“转写”页拖入音频、视频文件，或者粘贴视频链接。"))
            }
        }
    }

    /// 按天分组：今天、昨天、其他日期。
    private var groups: [(title: String, items: [LibraryItem])] {
        let calendar = Calendar.current
        var result: [(title: String, items: [LibraryItem])] = []
        for item in items {
            let title: String
            if calendar.isDateInToday(item.date) {
                title = String(localized: "今天")
            } else if calendar.isDateInYesterday(item.date) {
                title = String(localized: "昨天")
            } else {
                title = item.date.formatted(.dateTime.month().day().weekday())
            }
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append((title, [item]))
            }
        }
        return result
    }

    @ViewBuilder
    private func row(_ item: LibraryItem) -> some View {
        switch item {
        case .dictation(let entry):
            LibraryRow(item: item, status: nil, timeOnly: true) { navigation.openDictation(entry.id) } actions: {
                IconButton("doc.on.doc", help: "拷贝", size: 28) { Clipboard.copy(entry.output) }
                if entry.canReprocess {
                    ReprocessMenu(entry: entry, model: model, size: 28, onReprocess: actions.onReprocess)
                }
                IconButton("trash", help: "删除", size: 28, tint: Theme.danger) { model.dictations.delete(entry.id) }
            }
        case .meeting(let meeting):
            LibraryRow(item: item, status: RowStatus.meeting(meeting, processor: meetings.processor), timeOnly: true) {
                navigation.openMeeting(meeting.id)
            } actions: {
                if meetings.current?.id != meeting.id {
                    IconButton("trash", help: "删除会议…", size: 28, tint: Theme.danger) { deletingMeeting = meeting }
                }
            }
        case .transcription(let transcription):
            LibraryRow(item: item, status: RowStatus.transcription(transcription, controller: transcriber), timeOnly: true) {
                navigation.openTranscription(transcription.id, from: .library)
            } actions: {
                if transcriber.current != transcription.id {
                    IconButton("trash", help: "删除", size: 28, tint: Theme.danger) { deletingTranscription = transcription }
                }
            }
        }
    }
}

/// 卡片里的一列行，行和行之间一条细线（资料库、首页的最近、转写记录）。
struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .cardStyle()
    }
}

enum RowHover {
    #if DEBUG || TIDYTALK_DEV_TOOLS
    /// 截图用：假装鼠标停在这一行上
    nonisolated(unsafe) static var forced: String?
    static func isForced(_ id: String) -> Bool { forced == id }
    #else
    static func isForced(_ id: String) -> Bool { false }
    #endif
}

/// 列表的一行（设计稿的 Library Row）：类型图标方块、标题和类型长度、右边的时间或状态。
/// 有操作时，鼠标移上去整行变浅灰，时间换成几个图标按钮。
struct LibraryRow<Actions: View>: View {
    let item: LibraryItem
    /// 正在处理、出错时右边写状态；做完了写时间
    let status: RowStatus?
    /// 资料库按天分了组，只写几点几分
    var timeOnly = false
    /// 换掉第二行（转写页写“链接 · YouTube · 12 分钟”）
    var meta: String?
    let onOpen: () -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewState private var hovering = false

    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var showActions: Bool { (hovering || RowHover.isForced(item.id)) && hasActions }

    var body: some View {
        let symbol = status?.symbol ?? item.symbol
        HStack(spacing: 12) {
            Image(systemName: symbol.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(symbol.color)
                .frame(width: 32, height: 32)
                .background(showActions ? Theme.panel : Theme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(meta ?? item.meta).font(Theme.small).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                Group {
                    if let status, let text = status.text {
                        Text(text).foregroundStyle(status.color)
                    } else {
                        Text(RowTime.text(item.date, timeOnly: timeOnly)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .font(Theme.small.monospacedDigit())
                .opacity(showActions ? 0 : 1)
                if hasActions {
                    HStack(spacing: 2) { actions() }.opacity(showActions ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(showActions ? Theme.rowHover : hovering ? Theme.hover : .clear, in: Rectangle())
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }
}

extension LibraryRow where Actions == EmptyView {
    init(item: LibraryItem, status: RowStatus?, timeOnly: Bool = false, meta: String? = nil, onOpen: @escaping () -> Void) {
        self.init(item: item, status: status, timeOnly: timeOnly, meta: meta, onOpen: onOpen) { EmptyView() }
    }
}

/// "重新整理"菜单：四种整理模式（保持原文语言），以及翻译成各种语言（使用当前的整理模式）。
struct ReprocessMenu: View {
    let entry: HistoryEntry
    let model: AppModel
    var size: CGFloat = 32
    let onReprocess: (HistoryEntry, CleanupStyle, OutputLanguage) -> Void

    var body: some View {
        IconMenu(symbol: "wand.and.sparkles", help: "重新整理", size: size, tint: Theme.Tint.ai) {
            ForEach(CleanupStyle.allCases, id: \.self) { style in
                Button(style.title) { onReprocess(entry, style, .original) }
            }
            Divider()
            ForEach(OutputLanguage.allCases.filter(\.isTranslation), id: \.self) { language in
                Button(language.indicatorTag ?? language.title) {
                    onReprocess(entry, model.configStore.config.style, language)
                }
            }
        }
        .disabled(!model.cleanupEnabled)
    }
}

/// 一条说话记录（设计稿「说话记录详情」）：标题是时间，属性写类型、字数和保存在哪里；
/// 结果在上、原文在下，各有一个拷贝按钮。页头右边：拷贝、重新整理（只有说话输入有）、删除。
struct DictationDetailView: View {
    let id: UUID
    let model: AppModel
    let navigation: MainNavigation
    let actions: SettingsActions

    var body: some View {
        if let entry = model.dictations.entry(id) {
            VStack(spacing: 0) {
                PageHeader {
                    Breadcrumb(parent: navigation.section.title, title: DictationKind.title(entry.kind)) {
                        navigation.closeRecord()
                    }
                } trailing: {
                    IconButton("doc.on.doc", help: "拷贝") { Clipboard.copy(entry.output) }
                    if entry.canReprocess {
                        ReprocessMenu(entry: entry, model: model, onReprocess: actions.onReprocess)
                    }
                    IconButton("trash", help: "删除", tint: Theme.danger) {
                        navigation.closeRecord()
                        model.dictations.delete(entry.id)
                    }
                }
                PageBody {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(TranscribeFormat.date(entry.date))
                            .font(Theme.title).tracking(Theme.titleTracking).foregroundStyle(Theme.text)
                        ChipRow(spacing: 8) {
                            let style = DictationKind.style(entry.kind)
                            PropertyChip(symbol: style.name, text: DictationKind.title(entry.kind), tint: style.color)
                            PropertyChip(symbol: "text.alignleft", text: String(localized: "\(String(entry.output.count)) 字"))
                            if model.dictations.saving {
                                PropertyChip(symbol: "lock", text: String(localized: "保存在这台 Mac 上"), tint: Theme.Tint.local)
                            } else {
                                PropertyChip(symbol: "memorychip", text: String(localized: "只在内存里，退出后清空"))
                            }
                        }
                    }
                    TextBlock(title: String(localized: "结果"), text: entry.output, primary: true)
                    if entry.transcript != entry.output {
                        switch entry.kind {
                        case .dictation: TextBlock(title: String(localized: "识别原文"), text: entry.transcript, primary: false)
                        case .rewrite: TextBlock(title: String(localized: "修改要求"), text: entry.instruction, primary: false)
                        case .snippet: TextBlock(title: String(localized: "说出的话"), text: entry.transcript, primary: false)
                        }
                    }
                }
            }
        } else {
            RecordGoneView(navigation: navigation)
        }
    }
}

/// 一块带标题和拷贝按钮的文字（说话记录的结果、原文）。
struct TextBlock: View {
    let title: String
    let text: String
    let primary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Theme.captionMedium).foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton("doc.on.doc", helpText: String(localized: "拷贝\(title)"), size: 28) { Clipboard.copy(text) }
            }
            Text(text)
                .font(primary ? .system(size: 16) : Theme.body)
                .foregroundStyle(primary ? Theme.text : Theme.secondaryText)
                .lineSpacing(primary ? 9 : 7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
