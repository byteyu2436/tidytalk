import Testing
@testable import TidytalkCore

/// 更新提示只显示界面语言的那一半更新说明。
@Suite struct ReleaseNotesTests {
    static let notes = """
    - 会议记录：按 ⌃⌥M 同时录下两路声音。
    - 新的主窗口。

    安装：需要 macOS 26。

    - Meeting notes: press ⌃⌥M.
    - A new main window.

    Install: requires macOS 26.

    SHA-256 (Tidytalk-0.3.0.dmg): `abc`
    """

    @Test func chineseKeepsChineseBlocks() {
        #expect(ReleaseNotes.localized(Self.notes, chinese: true) == """
        - 会议记录：按 ⌃⌥M 同时录下两路声音。
        - 新的主窗口。

        安装：需要 macOS 26。
        """)
    }

    @Test func englishKeepsTheRest() {
        let english = ReleaseNotes.localized(Self.notes, chinese: false)
        #expect(english.hasPrefix("- Meeting notes"))
        #expect(english.contains("Install: requires macOS 26."))
        #expect(!english.contains("会议"))
    }

    @Test func singleLanguageIsUnchanged() {
        let only = "- Faster startup.\n\n- Fixed a crash."
        #expect(ReleaseNotes.localized(only, chinese: true) == only)
        #expect(ReleaseNotes.localized("- 修好闪退。", chinese: false) == "- 修好闪退。")
    }

    @Test func windowsLineEndingsAreHandled() {
        #expect(ReleaseNotes.localized("- 中文\r\n\r\n- English", chinese: true) == "- 中文")
    }
}
