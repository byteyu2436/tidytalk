import Foundation
import Testing
@testable import TidytalkCore

@Suite struct HandsFreeTests {
    typealias M = HotkeyStateMachine.Modifiers
    static let down = M(trigger: true, others: false)
    static let up = M(trigger: false, others: false)

    private func machine() -> HotkeyStateMachine {
        var sm = HotkeyStateMachine()
        sm.handsFreeEnabled = true
        return sm
    }

    @Test func doubleTapStartsAndTapStops() {
        var sm = machine()
        #expect(sm.handle(.modifiersChanged(Self.down), at: 0) == [.scheduleHoldTimer])
        #expect(sm.handle(.modifiersChanged(Self.up), at: 0.1) == [.cancelHoldTimer])
        #expect(sm.handle(.modifiersChanged(Self.down), at: 0.3) == [.startRecording])
        #expect(sm.handle(.modifiersChanged(Self.up), at: 0.4) == [])
        #expect(sm.state == .handsFree)
        // 打字、点鼠标不取消
        #expect(sm.handle(.keyDown) == [])
        #expect(sm.handle(.mouseDown) == [])
        #expect(sm.handle(.modifiersChanged(Self.down), at: 5) == [.finishRecording])
        #expect(sm.handle(.modifiersChanged(Self.up), at: 5.1) == [])
        #expect(sm.state == .idle)
    }

    @Test func slowSecondTapIsNotDoubleTap() {
        var sm = machine()
        _ = sm.handle(.modifiersChanged(Self.down), at: 0)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.1)
        #expect(sm.handle(.modifiersChanged(Self.down), at: 1.0) == [.scheduleHoldTimer])
    }

    @Test func keyBetweenTapsBreaksDoubleTap() {
        var sm = machine()
        _ = sm.handle(.modifiersChanged(Self.down), at: 0)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.1)
        _ = sm.handle(.keyDown)
        #expect(sm.handle(.modifiersChanged(Self.down), at: 0.2) == [.scheduleHoldTimer])
    }

    @Test func escapeCancelsHandsFree() {
        var sm = machine()
        _ = sm.handle(.modifiersChanged(Self.down), at: 0)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.1)
        _ = sm.handle(.modifiersChanged(Self.down), at: 0.2)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.3)
        #expect(sm.handle(.escapeDown) == [.cancelRecording])
        #expect(sm.state == .idle)
    }

    @Test func disabledDoubleTapUsesHoldMode() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.down), at: 0)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.1)
        #expect(sm.handle(.modifiersChanged(Self.down), at: 0.2) == [.scheduleHoldTimer])
    }

    @Test func escapeCancelsHoldRecording() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.down))
        _ = sm.handle(.holdTimerFired)
        #expect(sm.handle(.escapeDown) == [.cancelRecording])
    }

    @Test func limitInHandsFreeReturnsToIdle() {
        var sm = machine()
        _ = sm.handle(.modifiersChanged(Self.down), at: 0)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.1)
        _ = sm.handle(.modifiersChanged(Self.down), at: 0.2)
        _ = sm.handle(.modifiersChanged(Self.up), at: 0.3)
        #expect(sm.handle(.recordingEndedExternally) == [])
        #expect(sm.state == .idle)
    }
}

@Suite struct CleanupLevelTests {
    @Test func promptChangesWithLevel() {
        #expect(TranscriptCleanup.systemPrompt(level: .standard) == TranscriptCleanup.systemPrompt)
        #expect(TranscriptCleanup.systemPrompt(level: .light).contains("轻度"))
        #expect(TranscriptCleanup.systemPrompt(level: .thorough).contains("深度"))
    }

    @Test func thoroughAllowsMoreTrimming() {
        let raw = "我们今天开会主要就是说讨论了一下那个下个版本的发布时间然后大家觉得时间有点赶所以说就推迟一周吧"
        let cleaned = "会议决定下个版本推迟一周发布。"
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: cleaned) == nil)
        #expect(TranscriptCleanup.validate(raw: raw, cleaned: cleaned, level: .thorough) == cleaned)
    }
}

@Suite struct SnippetTests {
    let snippets = ["我的邮箱": "name@example.com", "Office address": "1 Infinite Loop"]

    @Test func wholeUtteranceMatches() {
        #expect(Snippets.expansion(for: "我的邮箱。", in: snippets) == "name@example.com")
        #expect(Snippets.expansion(for: " office address! ", in: snippets) == "1 Infinite Loop")
    }

    @Test func partialDoesNotMatch() {
        #expect(Snippets.expansion(for: "请发到我的邮箱", in: snippets) == nil)
        #expect(Snippets.expansion(for: "", in: snippets) == nil)
    }
}

@Suite struct RewriteTests {
    @Test func messagesContainSelectionAndInstruction() {
        let messages = RewritePrompt.messages(selection: "明天开会", instruction: "改得正式一点", vocabulary: ["Claude"])
        #expect(messages.count == 2)
        #expect(messages[0].content.contains("Claude"))
        #expect(messages[1].content.contains("<selection>\n明天开会\n</selection>"))
        #expect(messages[1].content.contains("改得正式一点"))
    }

    @Test func validation() {
        #expect(RewritePrompt.validate(selection: "明天开会", rewritten: "“定于明日召开会议。”") == "定于明日召开会议。")
        #expect(RewritePrompt.validate(selection: "明天开会", rewritten: "  ") == nil)
        #expect(RewritePrompt.validate(selection: "短", rewritten: String(repeating: "长", count: 3000)) == nil)
    }
}

@Suite struct VersionAndConfigTests {
    @Test func versionCompare() {
        #expect(AppVersion.isNewer("0.10.1", than: "0.9.3"))
        #expect(AppVersion.isNewer("v1.0", than: "0.9"))
        #expect(!AppVersion.isNewer("0.1.0", than: "0.1"))
        #expect(!AppVersion.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func newFieldsRoundTrip() throws {
        let config = AppConfig(handsFree: false, rewriteHotkey: nil, sounds: false, cleanupLevel: .thorough,
                               snippets: ["我的邮箱": "a@b.c"], autoUpdateCheck: false)
        #expect(try AppConfig.decode(config.encode()) == config)
        let defaults = try AppConfig.decode(Data("{}".utf8))
        #expect(defaults.handsFree && defaults.sounds && defaults.autoUpdateCheck)
        #expect(defaults.rewriteHotkey == .rightOption)
        #expect(defaults.cleanupLevel == .standard)
    }

    @Test func rewriteKeyCannotEqualHotkey() {
        #expect(AppConfig(hotkey: .rightOption, rewriteHotkey: .rightOption).rewriteHotkey == nil)
    }
}
