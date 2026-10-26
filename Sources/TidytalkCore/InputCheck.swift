import Foundation

/// 说话输入录音期间麦克风的情况：断开了没有、要不要重新打开，以及松开后怎么处理录到的声音。
///
/// 蓝牙耳机的麦克风打开时要先从听音乐的模式切到通话模式，这期间（约 1～2 秒）没有声音数据，
/// 或者只有一段全是 0 的数据，录音引擎还可能停下来（issue #1）。时间都是 `ProcessInfo.systemUptime`。
public enum InputCheck {
    /// 结束前这么久没有收到声音数据，就认为麦克风断开了。
    public static let lostAfter: TimeInterval = 1.5
    /// 录音期间这么久没有收到数据（从开始、上一次数据或上一次重新打开算起），就重新打开麦克风。
    public static let restartAfter: TimeInterval = 2
    /// 一次录音最多重新打开几次，免得坏掉的设备一直重试。
    public static let maxRestarts = 8
    /// 按住超过这么久却没录到声音，提示用户；更短的当成误触，直接收起。
    public static let noInputNoticeAfter: TimeInterval = 1
    /// 按下后过了这么久才收到真正的声音，开头说的话可能没录到。
    public static let lateStartAfter: TimeInterval = 0.8

    /// 麦克风断开后一直没有恢复：最近一段时间没有收到任何声音数据（不是安静，而是根本没有数据）。
    public static func lostInput(started: TimeInterval, lastData: TimeInterval?, now: TimeInterval) -> Bool {
        now - (lastData ?? started) > lostAfter
    }

    /// 要不要重新打开麦克风：引擎没在运行（上一次打开失败，或者停了却没有发通知）时马上再试；
    /// 运行中但很久没有数据时也重开。次数用完就不再试。
    public static func shouldRestart(started: TimeInterval, lastData: TimeInterval?, lastRestart: TimeInterval?,
                                     running: Bool, restarts: Int, now: TimeInterval) -> Bool {
        guard restarts < maxRestarts else { return false }
        guard running else { return true }
        let since = max(lastData ?? started, lastRestart ?? started)
        return now - since > restartAfter
    }

    /// 第一个不是 0 的样本的位置。麦克风切换模式期间送来的全 0 数据不算真正的声音。
    public static func firstSignal<C: Collection>(in samples: C) -> C.Index? where C.Element == Float {
        samples.firstIndex { $0 != 0 }
    }

    /// 松开后怎么处理。
    public enum Outcome: Equatable, Sendable {
        /// 按得太短（误触）：直接收起，不提示。
        case tooShort
        /// 按住了一会儿，但麦克风一直没有送来声音：没有数据、全是 0，或者有数据时已经快松开了。
        case noInput
        /// 录到了，交给识别。`lostTail`：中途断开后一直没恢复，后面的话没录到；
        /// `lateStart`：按下后过了一阵才有声音，开头的话可能没录到。
        case recorded(lostTail: Bool, lateStart: Bool)
    }

    /// - Parameters:
    ///   - held: 从开始录音到松开的时长。
    ///   - captured: 录到的音频时长（包括开头全是 0 的部分）。
    ///   - signalDelay: 从开始录音到收到第一个不是 0 的样本；一直没有时为 nil。
    ///   - lostInput: 见 `lostInput(started:lastData:now:)`。
    ///   - minimum: 最短的有效录音。
    public static func outcome(held: TimeInterval, captured: TimeInterval, signalDelay: TimeInterval?,
                               lostInput: Bool, minimum: TimeInterval) -> Outcome {
        if let signalDelay, captured >= minimum {
            return .recorded(lostTail: lostInput, lateStart: signalDelay >= lateStartAfter)
        }
        return held >= noInputNoticeAfter ? .noInput : .tooShort
    }
}
