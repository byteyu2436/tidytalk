import Foundation

/// 粘贴后什么时候恢复原来的剪贴板。
///
/// 剪贴板里放的是"用到时再提供"的文字，目标应用真正读取时会回调我们，这就是一次读取回执。
/// 收到回执后再安静一小段时间（有的应用会先探测、再读取）才恢复，不用猜固定的等待时间，
/// 应用卡顿时也不会读到恢复后的旧内容。
public struct PasteReceipts: Sendable {
    /// 最后一次读取后，再等这么久没有新的读取就恢复。
    public static let quietPeriod: TimeInterval = 0.2
    /// 模拟 ⌘V 之后一直没有读取（例如焦点不在输入框），最多等这么久。
    public static let noReceiptTimeout: TimeInterval = 4
    /// ⌘V 之前文字已经被读取过（剪贴板管理工具），之后的读取不会再回调，只能按固定时间等待。
    public static let fallbackDelay: TimeInterval = 0.6

    public enum Decision: Equatable, Sendable {
        case wait
        case restore
        /// 期间剪贴板被别的内容替换了，不恢复，免得覆盖用户刚复制的东西。
        case keep
    }

    public private(set) var pastedAt: TimeInterval?
    public private(set) var lastRead: TimeInterval?
    public private(set) var readBeforePaste = false
    public private(set) var replaced = false

    public init() {}

    /// 即将模拟 ⌘V。要在发送按键之前记下，反应快的应用可能在 ⌘ 还没松开时就读取了。
    public mutating func pasting(at time: TimeInterval) {
        pastedAt = time
    }

    public mutating func read(at time: TimeInterval) {
        if let pastedAt, time >= pastedAt {
            lastRead = time
        } else {
            readBeforePaste = true
        }
    }

    public mutating func contentReplaced() {
        replaced = true
    }

    public func decision(at now: TimeInterval) -> Decision {
        if replaced { return .keep }
        guard let pastedAt else { return .wait }
        if let lastRead { return now - lastRead >= Self.quietPeriod ? .restore : .wait }
        let limit = readBeforePaste ? Self.fallbackDelay : Self.noReceiptTimeout
        return now - pastedAt >= limit ? .restore : .wait
    }
}
