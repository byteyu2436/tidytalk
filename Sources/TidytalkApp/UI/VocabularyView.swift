import SwiftUI
import TidytalkCore

/// 「词库」（设计稿「主窗口 · 词库」）：常用词、固定替换、快捷短语、自定义规则四个标签，改动马上保存。
/// 粘贴后发现你改过的词时，在标签上面提示，可以一键加入。
struct VocabularyView: View {
    let model: AppModel
    var navigation: MainNavigation?

    enum Tab: Hashable { case terms, replacements, snippets, rules }

    @ViewState private var localTab: Tab = .terms
    private var tab: Tab {
        get { navigation?.vocabularyTab ?? localTab }
        nonmutating set { if let navigation { navigation.vocabularyTab = newValue } else { localTab = newValue } }
    }
    @ViewState private var newTerm = ""
    @ViewState private var newFrom = ""
    @ViewState private var newTo = ""
    @ViewState private var newRule = ""
    @FocusState private var focus: Tab?

    private var store: ConfigStore { model.configStore }
    private var config: AppConfig { store.config }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader { PageTitle(title: String(localized: "词库")) }
            PageBody {
                PageHeading(title: String(localized: "词库"),
                            message: String(localized: "让识别和 AI 整理用对你的写法。改动马上生效，不用保存。"))
                if !model.correctionSuggestions.isEmpty { suggestions }
                LinearTabs(selection: Binding(get: { tab }, set: { tab = $0 }), items: [
                    .init(value: .terms, title: String(localized: "常用词"), count: config.vocabulary.count),
                    .init(value: .replacements, title: String(localized: "固定替换"), count: config.replacements.count),
                    .init(value: .snippets, title: String(localized: "快捷短语"), count: config.snippets.count),
                    .init(value: .rules, title: String(localized: "自定义规则"), count: config.customRules.count),
                ])
                switch tab {
                case .terms: terms
                case .replacements: pairs(replacements: true)
                case .snippets: pairs(replacements: false)
                case .rules: rules
                }
            }
        }
        .onChange(of: tab) {
            newFrom = ""
            newTo = ""
        }
    }

    // MARK: - 发现你改过的词

    private var suggestions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Tint.vocabulary)
                Text("发现你改过的词").font(Theme.bodyMedium).foregroundStyle(Theme.text)
                Text("粘贴后你把左边改成了右边，加入词库后以后会自动改")
                    .font(Theme.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ForEach(model.correctionSuggestions) { correction in
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 10) {
                    Text(verbatim: correction.from).font(Theme.body).foregroundStyle(Theme.secondaryText)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    Text(verbatim: correction.to).font(Theme.bodyMedium).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    IconButton("xmark", help: "忽略", size: 28) { model.dismissCorrection(correction) }
                    IconButton("plus", help: "加入词库", size: 28, tint: Theme.Tint.vocabulary, outlined: true) {
                        accept(correction)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
            }
        }
        .cardStyle()
    }

    /// 加入词库：写进固定替换，右边的写法也加进常用词。
    private func accept(_ correction: WordCorrection) {
        _ = store.update { config in
            config.replacements[correction.from] = correction.to
            if !config.vocabulary.contains(where: { $0.caseInsensitiveCompare(correction.to) == .orderedSame }) {
                config.vocabulary.append(correction.to)
            }
        }
        model.dismissCorrection(correction)
    }

    // MARK: - 常用词

    private var terms: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("添加人名、产品名或术语，按回车加入", text: $newTerm)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .terms)
                    .onSubmit(addTerm)
                    .linearField(focused: focus == .terms)
                AddButton(action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if config.vocabulary.isEmpty {
                EmptyState(symbol: "character.book.closed", tint: Theme.Tint.vocabulary, title: String(localized: "还没有常用词"),
                           message: String(localized: "把人名、产品名、术语加进来，AI 整理时会把读音相近的词纠正成这些写法。"),
                           fill: false)
                    .padding(.top, -16)
                    .padding(.bottom, -28)
            } else {
                ChipRow(spacing: 8) {
                    ForEach(config.vocabulary, id: \.self) { term in
                        TermChip(term: term) { _ = store.update { $0.vocabulary.removeAll { $0 == term } } }
                    }
                }
                Text("AI 整理文字时会参考这些写法。没打开“整理文字”时不起作用。")
                    .font(Theme.small).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private func addTerm() {
        let terms = Vocabulary.normalize(config.vocabulary + [newTerm])
        guard terms != config.vocabulary else { newTerm = ""; return }
        _ = store.update { $0.vocabulary = terms }
        newTerm = ""
    }

    // MARK: - 固定替换、快捷短语

    @ViewBuilder
    private func pairs(replacements: Bool) -> some View {
        let values = replacements ? config.replacements : config.snippets
        let rows = values.sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
        VStack(spacing: 0) {
            if !rows.isEmpty {
                HStack(spacing: 12) {
                    Text(replacements ? "识别成" : "说出").frame(width: 200, alignment: .leading)
                    Spacer().frame(width: 14)
                    Text(replacements ? "替换为" : "输出")
                    Spacer()
                }
                .font(Theme.smallMedium)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.subtle, in: Rectangle())
                ForEach(rows, id: \.key) { row in
                    Rectangle().fill(Theme.border).frame(height: 1)
                    HStack(spacing: 12) {
                        Text(verbatim: row.key).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                            .frame(width: 200, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondaryText).frame(width: 14)
                        Text(verbatim: row.value).font(Theme.bodyMedium).foregroundStyle(Theme.text).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconButton("trash", help: "删除这一条", size: 28) {
                            _ = store.update {
                                if replacements { $0.replacements[row.key] = nil } else { $0.snippets[row.key] = nil }
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            HStack(spacing: 12) {
                TextField(replacements ? "识别成，例如 克劳德" : "说出，例如 我的邮箱", text: $newFrom)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: replacements ? .replacements : .snippets)
                    .onSubmit { addPair(replacements: replacements) }
                    .linearField()
                    .frame(width: 200)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText).frame(width: 14)
                TextField(replacements ? "替换为，例如 Claude" : "输出，例如 name@example.com", text: $newTo)
                    .textFieldStyle(.plain)
                    .onSubmit { addPair(replacements: replacements) }
                    .linearField()
                AddButton { addPair(replacements: replacements) }
                    .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                              || newTo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            if rows.isEmpty {
                if replacements {
                    EmptyState(symbol: "arrow.left.arrow.right", tint: Theme.Tint.vocabulary, title: String(localized: "还没有固定替换"),
                               message: String(localized: "识别成左边的词时换成右边的写法，例如“克劳德 → Claude”。"), fill: false)
                        .padding(.top, -16)
                } else {
                    EmptyState(symbol: "text.quote", tint: Theme.Tint.vocabulary, title: String(localized: "还没有快捷短语"),
                               message: String(localized: "只说出一个短语时，直接输出你设好的内容，比如邮箱、地址。"), fill: false)
                        .padding(.top, -16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .cardStyle()
        if !rows.isEmpty {
            Text(replacements ? "识别出左边的词时直接换成右边，不经过 AI，关掉“整理文字”也有效。"
                 : "只说出左边的短语时，直接输出右边的内容，适合邮箱、地址、常用链接。")
                .font(Theme.small).foregroundStyle(Theme.secondaryText)
        }
    }

    private func addPair(replacements: Bool) {
        let from = newFrom.trimmingCharacters(in: .whitespaces)
        let to = newTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        _ = store.update {
            if replacements { $0.replacements[from] = to } else { $0.snippets[from] = to }
        }
        newFrom = ""
        newTo = ""
    }

    // MARK: - 自定义规则

    @ViewBuilder
    private var rules: some View {
        VStack(spacing: 0) {
            ForEach(Array(config.customRules.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 12) {
                    Text(verbatim: String(index + 1)).font(Theme.caption).foregroundStyle(Theme.secondaryText)
                        .frame(width: 16, alignment: .leading)
                    Text(verbatim: rule).font(Theme.body).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton("trash", help: "删除这一条", size: 28) {
                        _ = store.update { $0.customRules.remove(at: index) }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            HStack(spacing: 8) {
                TextField("再加一条写法要求，按回车加入", text: $newRule)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .rules)
                    .onSubmit(addRule)
                    .linearField(focused: focus == .rules)
                AddButton(action: addRule)
                    .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty
                              || config.customRules.count >= CustomRules.limit)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            if config.customRules.isEmpty {
                EmptyState(symbol: "checklist", tint: Theme.Tint.vocabulary, title: String(localized: "还没有自定义规则"),
                           message: String(localized: "每条一个写法要求，AI 整理和改写时会遵守，例如“金额一律用阿拉伯数字”。"),
                           fill: false)
                    .padding(.top, -16)
            }
        }
        .cardStyle()
        if !config.customRules.isEmpty {
            HStack {
                Text("AI 整理和语音改写时会遵守这些要求。")
                Spacer()
                Text("\(String(config.customRules.count)) / \(String(CustomRules.limit)) 条")
            }
            .font(Theme.small)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private func addRule() {
        let rules = CustomRules.normalize(config.customRules + [newRule])
        guard rules != config.customRules else { newRule = ""; return }
        _ = store.update { $0.customRules = rules }
        newRule = ""
    }
}

/// 词库里的加号：橙色底、白色图标，和旁边的输入框一样高（36）。
private struct AddButton: View {
    let action: () -> Void

    var body: some View {
        IconButton("plus", help: "加入（回车）", size: 36, tint: Theme.Tint.vocabulary, prominent: true, action: action)
    }
}

/// 常用词的小标签：点叉号删除。
private struct TermChip: View {
    let term: String
    let onRemove: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: term).font(Theme.caption).foregroundStyle(Theme.text)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("删除“\(term)”")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }
}
