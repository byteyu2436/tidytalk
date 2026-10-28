import Foundation

/// 按住说话的触发键。
public enum HotkeyKey: String, CaseIterable, Sendable {
    /// 同时按住 Option 和 Command（默认）。
    case optionCommand = "option_command"
    case control
    case option
    case command
    case fn
    case rightOption = "right_option"
    case rightCommand = "right_command"

    public var title: String {
        switch self {
        case .optionCommand: "Option + Command"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .fn: String(localized: "Fn（🌐）")
        case .rightOption: String(localized: "右侧 Option")
        case .rightCommand: String(localized: "右侧 Command")
        }
    }

    /// 用在"按住 X 说话"之类的提示里。
    public var shortName: String {
        switch self {
        case .optionCommand: "Option + Command"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .fn: "Fn"
        case .rightOption: String(localized: "右 Option")
        case .rightCommand: String(localized: "右 Command")
        }
    }

    /// 键帽上的符号，用在快捷键提示（⌥⌘、右 ⌥）里。
    public var symbol: String {
        switch self {
        case .optionCommand: "⌥⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .fn: "Fn"
        case .rightOption: String(localized: "右 ⌥")
        case .rightCommand: String(localized: "右 ⌘")
        }
    }

    /// CGEventFlags 的原始位。放在这里而不是引用 CoreGraphics，方便单元测试。
    public enum Flag {
        public static let shift: UInt64 = 0x0002_0000
        public static let control: UInt64 = 0x0004_0000
        public static let option: UInt64 = 0x0008_0000
        public static let command: UInt64 = 0x0010_0000
        public static let fn: UInt64 = 0x0080_0000
        // 区分左右的设备位（NX_DEVICE*KEYMASK）
        public static let leftCommand: UInt64 = 0x0008
        public static let rightCommand: UInt64 = 0x0010
        public static let leftOption: UInt64 = 0x0020
        public static let rightOption: UInt64 = 0x0040
    }

    /// 根据当前的修饰键状态判断触发键是否按着、有没有同时按着别的修饰键。
    public func modifiers(fromFlags flags: UInt64) -> HotkeyStateMachine.Modifiers {
        func has(_ bit: UInt64) -> Bool { flags & bit != 0 }
        let all: [(UInt64, HotkeyKey)] = [
            (Flag.control, .control), (Flag.option, .option), (Flag.command, .command), (Flag.fn, .fn),
        ]
        let shift = has(Flag.shift)

        switch self {
        case .optionCommand:
            // 两个键都按着才算按下；Shift、Control、Fn 算作别的键
            return .init(trigger: has(Flag.option) && has(Flag.command),
                         others: shift || has(Flag.control) || has(Flag.fn))
        case .control, .option, .command, .fn:
            let trigger = all.first { $0.1 == self }!.0
            let others = shift || all.contains { $0.1 != self && has($0.0) }
            return .init(trigger: has(trigger), others: others)
        case .rightOption:
            let others = shift || has(Flag.control) || has(Flag.command) || has(Flag.fn) || has(Flag.leftOption)
            return .init(trigger: has(Flag.rightOption), others: others)
        case .rightCommand:
            let others = shift || has(Flag.control) || has(Flag.option) || has(Flag.fn) || has(Flag.leftCommand)
            return .init(trigger: has(Flag.rightCommand), others: others)
        }
    }
}
