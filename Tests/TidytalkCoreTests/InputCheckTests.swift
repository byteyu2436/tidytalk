import Foundation
import Testing
@testable import TidytalkCore

/// 麦克风开头没有声音、中途断开时的判断（issue #1：蓝牙耳机切换到通话模式要一两秒）。
@Suite struct InputCheckTests {
    @Test func lostInputCountsFromStartWhenNoDataEverArrived() {
        #expect(!InputCheck.lostInput(started: 100, lastData: nil, now: 101))
        #expect(InputCheck.lostInput(started: 100, lastData: nil, now: 102))
    }

    @Test func lostInputOnlyWhenDataStoppedNearTheEnd() {
        // 中途断了一阵又恢复：不算
        #expect(!InputCheck.lostInput(started: 100, lastData: 104.9, now: 105))
        #expect(InputCheck.lostInput(started: 100, lastData: 103, now: 105))
    }

    @Test func restartsRightAwayAfterAFailedOpen() {
        #expect(InputCheck.shouldRestart(started: 100, lastData: nil, lastRestart: 100.2, running: false,
                                         restarts: 1, now: 100.5))
    }

    @Test func restartsWhenRunningButSilentForTooLong() {
        // 从开始算：2 秒内不动，超过就重开
        #expect(!InputCheck.shouldRestart(started: 100, lastData: nil, lastRestart: nil, running: true,
                                          restarts: 0, now: 101.5))
        #expect(InputCheck.shouldRestart(started: 100, lastData: nil, lastRestart: nil, running: true,
                                         restarts: 0, now: 102.5))
        // 一直有数据：不重开
        #expect(!InputCheck.shouldRestart(started: 100, lastData: 109.9, lastRestart: nil, running: true,
                                          restarts: 0, now: 110))
        // 刚重新打开过：从那时起再等 2 秒
        #expect(!InputCheck.shouldRestart(started: 100, lastData: nil, lastRestart: 102.5, running: true,
                                          restarts: 1, now: 103))
    }

    @Test func givesUpAfterTooManyRestarts() {
        #expect(!InputCheck.shouldRestart(started: 100, lastData: nil, lastRestart: 100, running: false,
                                          restarts: InputCheck.maxRestarts, now: 130))
    }

    @Test func allZeroDataIsNotSignal() {
        #expect(InputCheck.firstSignal(in: [Float](repeating: 0, count: 800)) == nil)
        #expect(InputCheck.firstSignal(in: [0, 0, 0.0001, 0.2] as [Float]) == 2)
        #expect(InputCheck.firstSignal(in: [] as [Float]) == nil)
    }

    @Test func quickTapIsIgnored() {
        #expect(InputCheck.outcome(held: 0.3, captured: 0.25, signalDelay: 0.05, lostInput: false, minimum: 0.5)
            == .tooShort)
        // 误触且麦克风还没准备好：同样不打扰
        #expect(InputCheck.outcome(held: 0.8, captured: 0, signalDelay: nil, lostInput: false, minimum: 0.5)
            == .tooShort)
    }

    @Test func normalRecording() {
        #expect(InputCheck.outcome(held: 3, captured: 2.95, signalDelay: 0.05, lostInput: false, minimum: 0.5)
            == .recorded(lostTail: false, lateStart: false))
    }

    /// 以前按住说了两秒、麦克风一直没数据时，指示器悄悄收起，用户不知道发生了什么。
    @Test func heldButMicrophoneNeverDelivered() {
        #expect(InputCheck.outcome(held: 2, captured: 0, signalDelay: nil, lostInput: true, minimum: 0.5)
            == .noInput)
    }

    @Test func microphoneReadyOnlyJustBeforeRelease() {
        // 1.6 秒后才有数据，只录到最后 0.3 秒
        #expect(InputCheck.outcome(held: 1.9, captured: 0.3, signalDelay: 1.6, lostInput: false, minimum: 0.5)
            == .noInput)
    }

    @Test func onlyZerosCountsAsNoInput() {
        // 送来的全是 0（切换模式中、麦克风被静音）
        #expect(InputCheck.outcome(held: 2, captured: 1.9, signalDelay: nil, lostInput: false, minimum: 0.5)
            == .noInput)
    }

    @Test func lateStartIsRecordedButFlagged() {
        #expect(InputCheck.outcome(held: 4, captured: 3.9, signalDelay: 1.5, lostInput: false, minimum: 0.5)
            == .recorded(lostTail: false, lateStart: true))
        #expect(InputCheck.outcome(held: 4, captured: 3.9, signalDelay: 0.3, lostInput: false, minimum: 0.5)
            == .recorded(lostTail: false, lateStart: false))
    }

    @Test func droppedOutNearTheEnd() {
        #expect(InputCheck.outcome(held: 5, captured: 3, signalDelay: 0.05, lostInput: true, minimum: 0.5)
            == .recorded(lostTail: true, lateStart: false))
    }
}
