import Testing
@testable import TidytalkCore

@Suite struct HotkeyStateMachineTests {
    typealias M = HotkeyStateMachine.Modifiers
    static let ctrl = M(trigger: true, others: false)
    static let none = M(trigger: false, others: false)
    static let ctrlShift = M(trigger: true, others: true)
    static let shift = M(trigger: false, others: true)

    @Test func holdAndReleaseRecords() {
        var sm = HotkeyStateMachine()
        #expect(sm.handle(.modifiersChanged(Self.ctrl)) == [.scheduleHoldTimer])
        #expect(sm.handle(.holdTimerFired) == [.startRecording])
        #expect(sm.state == .recording)
        #expect(sm.handle(.modifiersChanged(Self.none)) == [.finishRecording])
        #expect(sm.state == .idle)
    }

    @Test func shortPressDoesNothing() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.ctrl))
        #expect(sm.handle(.modifiersChanged(Self.none)) == [.cancelHoldTimer])
        #expect(sm.handle(.holdTimerFired) == [])
        #expect(sm.state == .idle)
    }

    @Test func controlShortcutDoesNotTrigger() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.ctrl))
        #expect(sm.handle(.keyDown) == [.cancelHoldTimer])
        #expect(sm.handle(.holdTimerFired) == [])
        #expect(sm.state == .blocked)
        _ = sm.handle(.modifiersChanged(Self.none))
        #expect(sm.state == .idle)
    }

    @Test func otherModifierHeldFirstDoesNotTrigger() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.shift))
        #expect(sm.handle(.modifiersChanged(Self.ctrlShift)) == [])
        #expect(sm.state == .blocked)
        // 松开 Shift 但 Control 还按着，也不应开始
        #expect(sm.handle(.modifiersChanged(Self.ctrl)) == [])
        #expect(sm.handle(.holdTimerFired) == [])
    }

    @Test func keyDuringRecordingCancels() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.ctrl))
        _ = sm.handle(.holdTimerFired)
        #expect(sm.handle(.keyDown) == [.cancelRecording])
        #expect(sm.handle(.modifiersChanged(Self.none)) == [])
        #expect(sm.state == .idle)
    }

    @Test func mouseOrModifierDuringRecordingCancels() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.ctrl))
        _ = sm.handle(.holdTimerFired)
        #expect(sm.handle(.mouseDown) == [.cancelRecording])

        var sm2 = HotkeyStateMachine()
        _ = sm2.handle(.modifiersChanged(Self.ctrl))
        _ = sm2.handle(.holdTimerFired)
        #expect(sm2.handle(.modifiersChanged(Self.ctrlShift)) == [.cancelRecording])
    }

    @Test func externalEndWaitsForRelease() {
        var sm = HotkeyStateMachine()
        _ = sm.handle(.modifiersChanged(Self.ctrl))
        _ = sm.handle(.holdTimerFired)
        #expect(sm.handle(.recordingEndedExternally) == [])
        #expect(sm.handle(.modifiersChanged(Self.none)) == [])
        #expect(sm.handle(.modifiersChanged(Self.ctrl)) == [.scheduleHoldTimer])
    }
}
