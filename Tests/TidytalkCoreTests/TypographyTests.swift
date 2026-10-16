import Testing
@testable import TidytalkCore

@Suite struct TypographyTests {
    @Test func spacesBetweenChineseAndLatin() {
        #expect(Typography.format("用API调5次") == "用 API 调 5 次")
        #expect(Typography.format("这个demo不错") == "这个 demo 不错")
        #expect(Typography.format("增长了50%的用户") == "增长了 50% 的用户")
    }

    @Test func keepsExistingSpacesAndPureEnglish() {
        #expect(Typography.format("用 API 调用") == "用 API 调用")
        #expect(Typography.format("So I think we should ship it.") == "So I think we should ship it.")
    }

    @Test func convertsPunctuationAfterChinese() {
        #expect(Typography.format("好的,明天见.") == "好的，明天见。")
        #expect(Typography.format("真的吗?太好了!") == "真的吗？太好了！")
    }

    @Test func leavesTechnicalPunctuationAlone() {
        #expect(Typography.format("版本是3.5") == "版本是 3.5")
        #expect(Typography.format("打开README.md文件") == "打开 README.md 文件")
        #expect(Typography.format("等一下...") == "等一下...")
        #expect(Typography.format("hello, world") == "hello, world")
    }

    @Test func noSpacesAroundFullWidthPunctuation() {
        #expect(Typography.format("用 API ，然后 SDK 。") == "用 API，然后 SDK。")
        #expect(Typography.format("我说 “好的” 吧") == "我说“好的”吧")
    }

    @Test func fullWidthAlphanumericToHalfWidth() {
        #expect(Typography.format("ＡＰＩ１２３") == "API123")
        #expect(Typography.format("用ＡＰＩ") == "用 API")
    }

    @Test func codeStyleKeepsPunctuation() {
        #expect(Typography.format("运行npm install,然后", convertPunctuation: false) == "运行 npm install,然后")
    }
}
