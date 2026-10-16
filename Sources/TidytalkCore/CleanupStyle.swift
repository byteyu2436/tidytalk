import Foundation

/// 整理模式，在设置里手动切换。
public enum CleanupStyle: String, CaseIterable, Sendable {
    case standard
    /// 聊天：保持口语化。
    case casual
    /// 书面：邮件、文档，更正式。
    case formal
    /// 代码：严格保留术语和符号。
    case code

    public var title: String {
        switch self {
        case .standard: String(localized: "标准")
        case .casual: String(localized: "聊天（口语）")
        case .formal: String(localized: "邮件（书面）")
        case .code: String(localized: "代码（保留术语）")
        }
    }

    public var summary: String {
        switch self {
        case .standard: String(localized: "删除填充词、修正口误、补全标点，保持原意。")
        case .casual: String(localized: "保留口语语气，适合聊天。")
        case .formal: String(localized: "改成书面表达，适合邮件和文档。")
        case .code: String(localized: "原样保留术语、命令和符号，适合技术内容。")
        }
    }

    /// 追加到系统提示里的模式说明；标准模式不追加。
    var instruction: String? {
        switch self {
        case .standard:
            nil
        case .casual:
            """
            当前场景是聊天：保持口语化的语气和用词，不要改成书面语；句子保持简短自然；\
            表达语气的句末词（例如"吧""呢""哈""啦"）要保留；最后一句末尾可以不加句号。
            """
        case .formal:
            """
            当前场景是邮件或正式文档：使用规范的书面表达，句子完整、标点齐全；可以把明显口语化的说法\
            换成对应的书面说法（例如"搞定"改为"完成"），但不得增加、删减或改变任何信息。
            """
        case .code:
            """
            当前场景是代码编辑器或终端：严格保留英文术语、变量名、函数名、命令、文件名、路径的原样，\
            包括大小写和其中的符号；不要把技术词翻译成中文，也不要添加修饰性的标点或语气。
            """
        }
    }
}
