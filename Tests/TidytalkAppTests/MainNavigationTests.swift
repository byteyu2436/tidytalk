import Testing
@testable import TidytalkApp

/// 设置在主窗口里：打开、切页、回来（docs/meeting-mode.md M34）。
@MainActor
@Suite struct MainNavigationTests {
    @Test func settingsOpenOnTheLastPageViewed() {
        let navigation = MainNavigation()
        #expect(navigation.settings == nil)
        navigation.openSettings()
        #expect(navigation.settings == .general)
        navigation.openSettings(.captions)
        navigation.closeSettings()
        #expect(navigation.settings == nil)
        // ⌘, 再打开时回到上次看的那一页
        navigation.openSettings()
        #expect(navigation.settings == .captions)
    }

    @Test func closingSettingsKeepsThePageUnderneath() {
        let navigation = MainNavigation()
        navigation.section = .transcribe
        navigation.openSettings(.ai)
        navigation.closeSettings()
        #expect(navigation.section == .transcribe)
    }

    @Test func showingASectionLeavesSettings() {
        let navigation = MainNavigation()
        navigation.openSettings(.models)
        navigation.show(.history)
        #expect(navigation.settings == nil)
        #expect(navigation.section == .history)
    }

    @Test func vocabularyIsOnlyAMainSection() {
        // 词库只在主窗口里，设置里不再重复
        #expect(!MainNavigation.SettingsPage.allCases.map(\.title).contains(MainNavigation.Section.vocabulary.title))
    }
}
