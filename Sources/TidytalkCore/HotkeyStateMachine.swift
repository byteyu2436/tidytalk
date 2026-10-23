import Foundation

/// 按住触发键（默认 Control，可在设置里更换）录音的判定逻辑，与系统事件解耦，便于测试。
///
/// 按住模式：
/// - 单独按下触发键并保持约 0.4 秒后开始录音；提前松开视为普通短按。
/// - 已按着其他修饰键时再按触发键，不触发。
/// - 等待或录音期间按下其他键、其他修饰键、Esc，或点击鼠标，取消本次录音。
/// - 松开触发键结束录音。
/// - 被取消或达到时长上限后，要等触发键松开才能开始下一次。
///
/// 免按住模式（`handsFreeEnabled` 为 true 时）：
/// - 快速双击触发键，第二次按下时立即开始录音，松开后继续录音。
/// - 再按一次触发键结束录音；按 Esc 取消。
/// - 录音期间打字、点击鼠标不会取消，方便边说边切换输入框。
///
/// 外部触发（tidytalk://toggle，可以从 Raycast、快捷指令调用）：空闲时按免按住模式开始录音，录音中则结束录音。
public struct HotkeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// 触发键已按下，等待保持时间。
        case pending
        case recording
        /// 双击开始的录音，第二次按下的触发键还没松开。
        case handsFreeHolding
        /// 双击开始的录音，触发键已松开，等待再按一次结束。
        case handsFree
        /// 本次按下已作废，等待触发键松开。
        case blocked
    }

    public struct Modifiers: Equatable, Sendable {
        /// 触发键是否按着。
        public var trigger: Bool
        /// 除触发键以外的任意修饰键。
        public var others: Bool

        public init(trigger: Bool, others: Bool) {
            self.trigger = trigger
            self.others = others
        }
    }

    public enum Event: Equatable, Sendable {
        case modifiersChanged(Modifiers)
        case keyDown
        /// Esc 键，在任何录音状态下都取消录音。
        case escapeDown
        case mouseDown
        case holdTimerFired
        /// 录音因时长上限或启动失败等原因在外部结束。
        case recordingEndedExternally
        /// 从应用外部开始或结束录音（tidytalk://toggle）。
        case externalToggle
    }

    public enum Action: Equatable, Sendable {
        case scheduleHoldTimer
        case cancelHoldTimer
        case startRecording
        case finishRecording
        case cancelRecording
    }

    /// 两次短按之间最长的间隔，超过就不算双击。
    public static let doubleTapWindow: TimeInterval = 0.35

    public private(set) var state: State = .idle
    /// 是否允许双击进入免按住录音，每次处理事件前由调用方根据设置更新。
    public var handsFreeEnabled = false
    /// 上一次短按（按下后在保持时间内松开）松开的时间，用于判断双击。
    private var lastTapRelease: TimeInterval?

    public var isHandsFree: Bool { state == .handsFree || state == .handsFreeHolding }

    public init() {}

    /// - Parameter time: 事件发生的时间（秒，单调递增即可），用于判断双击。
    public mutating func handle(_ event: Event, at time: TimeInterval = 0) -> [Action] {
        switch (state, event) {
        case (.idle, .modifiersChanged(let m)):
            guard m.trigger else { return [] }
            if m.others {
                lastTapRelease = nil
                state = .blocked
                return []
            }
            if handsFreeEnabled, let release = lastTapRelease, time - release <= Self.doubleTapWindow {
                lastTapRelease = nil
                state = .handsFreeHolding
                return [.startRecording]
            }
            state = .pending
            return [.scheduleHoldTimer]

        case (.idle, .externalToggle):
            // 按免按住录音处理：打字、点击不会取消，再触发一次或按触发键结束，Esc 取消
            lastTapRelease = nil
            state = .handsFree
            return [.startRecording]

        case (.handsFree, .externalToggle):
            state = .idle
            return [.finishRecording]

        case (.recording, .externalToggle), (.handsFreeHolding, .externalToggle):
            // 触发键还按着，等松开后才能开始下一次
            state = .blocked
            return [.finishRecording]

        case (.idle, .keyDown), (.idle, .escapeDown), (.idle, .mouseDown):
            // 两次短按之间有其他操作，不算双击
            lastTapRelease = nil
            return []

        case (.pending, .modifiersChanged(let m)):
            if !m.trigger {
                state = .idle
                lastTapRelease = time
                return [.cancelHoldTimer]
            }
            if m.others {
                state = .blocked
                return [.cancelHoldTimer]
            }
            return []

        case (.pending, .keyDown), (.pending, .escapeDown), (.pending, .mouseDown):
            state = .blocked
            return [.cancelHoldTimer]

        case (.pending, .holdTimerFired):
            state = .recording
            return [.startRecording]

        case (.recording, .modifiersChanged(let m)):
            if !m.trigger {
                state = .idle
                return [.finishRecording]
            }
            if m.others {
                state = .blocked
                return [.cancelRecording]
            }
            return []

        case (.recording, .keyDown), (.recording, .escapeDown), (.recording, .mouseDown):
            state = .blocked
            return [.cancelRecording]

        case (.handsFreeHolding, .modifiersChanged(let m)):
            if !m.trigger {
                state = .handsFree
                return []
            }
            if m.others {
                state = .blocked
                return [.cancelRecording]
            }
            return []

        case (.handsFreeHolding, .escapeDown):
            state = .blocked
            return [.cancelRecording]

        case (.handsFree, .modifiersChanged(let m)):
            // 再按一次触发键结束；等松开后才能开始下一次
            guard m.trigger, !m.others else { return [] }
            state = .blocked
            return [.finishRecording]

        case (.handsFree, .escapeDown):
            state = .idle
            return [.cancelRecording]

        case (.recording, .recordingEndedExternally), (.handsFreeHolding, .recordingEndedExternally):
            state = .blocked
            return []

        case (.handsFree, .recordingEndedExternally):
            // 触发键没有按着，直接回到空闲
            state = .idle
            return []

        case (.blocked, .modifiersChanged(let m)):
            if !m.trigger { state = .idle }
            return []

        default:
            return []
        }
    }
}
