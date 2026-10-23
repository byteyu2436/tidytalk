import Foundation

/// 识别结果进入 AI 整理之前和粘贴之前的本地处理，整理开关关闭时同样生效。
public enum TextPipeline {
    /// 整理前：按固定替换表纠正常见的识别错误，再把和词库里"差一点"的词改成词库的写法，
    /// 让 AI 看到的已经是正确写法。只在这里替换一次，避免"Claude → Claude Code"这类规则被重复套用。
    public static func prepare(_ transcript: String, config: AppConfig) -> String {
        let replaced = Vocabulary.applyReplacements(config.replacements, to: transcript)
        return VocabularyMatcher.correct(replaced, terms: config.vocabulary)
    }

    /// 粘贴前：中英文排版规范。代码场景不转换标点，避免改动代码里的符号。
    /// `language` 是实际输出的语言：译成日文等其他语言时不套用中文排版（日文数字两侧不加空格）；
    /// 翻译失败回退原文时传 `.original`。
    public static func finish(_ text: String, config: AppConfig, style: CleanupStyle,
                              language: OutputLanguage = .original) -> String {
        guard config.typography, language.usesChineseTypography else { return text }
        // 直接说日文时（原文输出）不套用中文排版：日文里英文和假名之间不加空格，也不用中文的全角逗号
        if language == .original, Typography.containsKana(text) { return text }
        return Typography.format(text, convertPunctuation: style != .code)
    }
}
