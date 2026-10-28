import Foundation
import Testing
@testable import TidytalkApp

/// 设置在主窗口里：打开、切页、回来（docs/meeting-mode.md M34）。
@MainActor
@Suite struct MainNavigationTests {
    @Test func settingsOpenOnTheLastPageViewed() {
        let navigation = MainNavigation()
        #expect(navigation.settings == nil)
        navigation.openSettings()
        // 第一次打开是侧边栏最上面的"说话输入"
        #expect(navigation.settings == .dictation)
        navigation.openSettings(.captions)
        navigation.closeSettings()
        #expect(navigation.settings == nil)
        // ⌘, 再打开时回到上次看的那一页
        navigation.openSettings()
        #expect(navigation.settings == .captions)
    }

    @Test func closingSettingsKeepsThePageUnderneath() {
        let navigation = MainNavigation()
        navigation.section = .library
        navigation.openSettings(.ai)
        navigation.closeSettings()
        #expect(navigation.section == .library)
    }

    @Test func showingASectionLeavesSettings() {
        let navigation = MainNavigation()
        navigation.openSettings(.models)
        navigation.show(.vocabulary)
        #expect(navigation.settings == nil)
        #expect(navigation.section == .vocabulary)
    }

    @Test func openingARecordGoesToTheLibraryAndClosesTheOthers() {
        let navigation = MainNavigation()
        navigation.openSettings(.ai)
        navigation.openTranscription(UUID())
        let meeting = UUID()
        navigation.openMeeting(meeting)
        #expect(navigation.settings == nil)
        #expect(navigation.section == .library)
        #expect(navigation.meeting == meeting)
        #expect(navigation.transcription == nil)
        navigation.closeRecord()
        #expect(navigation.meeting == nil)
    }

    @Test func transcriptionsOpenWhereTheyWereClicked() {
        // 从“转写”页点进去：侧边栏选中转写，返回回到转写页
        let navigation = MainNavigation()
        let id = UUID()
        navigation.openTranscription(id)
        #expect(navigation.section == .transcribe)
        #expect(navigation.transcription == id)
        // 从资料库点进去：返回回到资料库
        navigation.openTranscription(id, from: .library)
        #expect(navigation.section == .library)
        navigation.closeRecord()
        #expect(navigation.transcription == nil)
        #expect(navigation.section == .library)
    }

    @Test func sidebarHasFourSectionsInOrder() {
        // ⌘1–⌘4 按这个顺序
        #expect(MainNavigation.Section.allCases == [.home, .transcribe, .library, .vocabulary])
    }

    @Test func showingASectionClosesTheOpenRecord() {
        let navigation = MainNavigation()
        navigation.openMeeting(UUID())
        navigation.show(.library)
        #expect(navigation.meeting == nil)
        #expect(!navigation.hasRecord)
    }

    @Test func vocabularyIsOnlyAMainSection() {
        // 词库只在主窗口里，设置里不再重复
        #expect(!MainNavigation.SettingsPage.allCases.map(\.title).contains(MainNavigation.Section.vocabulary.title))
    }
}
