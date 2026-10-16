import Foundation

/// 识别结果进入 AI 整理之前和粘贴之前的本地处理，整理开关关闭时同样生效。
public enum TextPipeline {
    /// 整理前：按固定替换表纠正常见的识别错误，让 AI 看到的已经是正确写法。
    /// 只在这里替换一次，避免"Claude → Claude Code"这类规则被重复套用。
    public static func prepare(_ transcript: String, config: AppConfig) -> String {
        Vocabulary.applyReplacements(config.replacements, to: transcript)
    }

    /// 粘贴前：中英文排版规范。代码场景不转换标点，避免改动代码里的符号。
    /// `language` 是实际输出的语言：译成日文等其他语言时不套用中文排版（日文数字两侧不加空格）；
    /// 翻译失败回退原文时传 `.original`。
    public static func finish(_ text: String, config: AppConfig, style: CleanupStyle,
                              language: OutputLanguage = .original) -> String {
        guard config.typography, language.usesChineseTypography else { return text }
        return Typography.format(text, convertPunctuation: style != .code)
    }
}
