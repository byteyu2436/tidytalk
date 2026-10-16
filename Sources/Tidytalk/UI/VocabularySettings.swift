import SwiftUI
import TidytalkCore

/// 个人词库和固定替换表。
struct VocabularySettings: View {
    let model: AppModel

    @ViewState private var termsText = ""
    @ViewState private var rulesText = ""
    @ViewState private var rows: [ReplacementRow] = []
    @ViewState private var snippetRows: [ReplacementRow] = []
    @ViewState private var saved = false

    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
    }

    private var store: ConfigStore { model.configStore }

    private var draftTerms: [String] {
        Vocabulary.normalize(termsText.components(separatedBy: .newlines))
    }

    private var draftReplacements: [String: String] { Self.dictionary(rows) }

    private var draftRules: [String] {
        CustomRules.normalize(rulesText.components(separatedBy: .newlines))
    }

    private var draftSnippets: [String: String] { Self.dictionary(snippetRows) }

    private static func dictionary(_ rows: [ReplacementRow]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let from = row.from.trimmingCharacters(in: .whitespaces)
            let to = row.to.trimmingCharacters(in: .whitespaces)
            if !from.isEmpty, !to.isEmpty, from != to { result[from] = to }
        }
        return result
    }

    private var isDirty: Bool {
        draftTerms != store.config.vocabulary || draftReplacements != store.config.replacements
            || draftSnippets != store.config.snippets || draftRules != store.config.customRules
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $termsText)
                    .font(.body)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if termsText.isEmpty {
                            Text("例如：\nClaude\nSenseVoice\n张伟")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("常用词")
            } footer: {
                Text("每行一个人名、产品名或术语，AI 会把读音相近的词纠正成这些写法。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($rows) { $row in
                    HStack {
                        TextField("识别成", text: $row.from, prompt: Text("克劳德"))
                            .labelsHidden()
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("替换为", text: $row.to, prompt: Text("Claude"))
                            .labelsHidden()
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    rows.append(ReplacementRow(from: "", to: ""))
                } label: {
                    Label("添加替换", systemImage: "plus")
                }
            } header: {
                Text("固定替换")
            } footer: {
                Text("识别出左边的词时，替换成右边的写法。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($snippetRows) { $row in
                    HStack(alignment: .top) {
                        TextField("说出", text: $row.from, prompt: Text("我的邮箱"))
                            .labelsHidden()
                            .frame(width: 150)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 4)
                        TextField("输出", text: $row.to, prompt: Text("name@example.com"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...4)
                        Button {
                            snippetRows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                Button {
                    snippetRows.append(ReplacementRow(from: "", to: ""))
                } label: {
                    Label("添加快捷短语", systemImage: "plus")
                }
            } header: {
                Text("快捷短语")
            } footer: {
                Text("只说出左边的短语时，直接输出右边的内容，适合邮箱、地址等。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $rulesText)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if rulesText.isEmpty {
                            Text("例如：\n金额一律用阿拉伯数字\n称呼对方统一用\"您\"\n产品名写作 Tidytalk")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("自定义规则")
            } footer: {
                Text("每行一条写法要求，AI 整理和改写时会遵守。最多 \(CustomRules.limit) 条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if saved && !isDirty {
                        Label("已保存", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else if isDirty {
                        Text("有未保存的修改").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("还原", action: load).disabled(!isDirty)
                    Button("保存", action: save)
                        .keyboardShortcut("s")
                        .disabled(!isDirty)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        store.reload()
        termsText = store.config.vocabulary.joined(separator: "\n")
        rulesText = store.config.customRules.joined(separator: "\n")
        rows = store.config.replacements
            .sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(from: $0.key, to: $0.value) }
        snippetRows = store.config.snippets
            .sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(from: $0.key, to: $0.value) }
        saved = false
    }

    private func save() {
        let terms = draftTerms
        let replacements = draftReplacements
        let snippets = draftSnippets
        let rules = draftRules
        saved = store.update {
            $0.customRules = rules
            $0.vocabulary = terms
            $0.replacements = replacements
            $0.snippets = snippets
        }
        termsText = terms.joined(separator: "\n")
        rulesText = rules.joined(separator: "\n")
    }
}
