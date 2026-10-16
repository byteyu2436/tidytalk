import Foundation
import Testing
@testable import TidytalkCore

@Suite struct HotkeyKeyTests {
    typealias F = HotkeyKey.Flag

    @Test func controlIgnoresOtherSideBits() {
        #expect(HotkeyKey.control.modifiers(fromFlags: F.control) == .init(trigger: true, others: false))
        #expect(HotkeyKey.control.modifiers(fromFlags: F.control | F.shift) == .init(trigger: true, others: true))
        #expect(HotkeyKey.control.modifiers(fromFlags: 0) == .init(trigger: false, others: false))
    }

    @Test func optionAndCommand() {
        #expect(HotkeyKey.option.modifiers(fromFlags: F.option | F.leftOption) == .init(trigger: true, others: false))
        #expect(HotkeyKey.option.modifiers(fromFlags: F.option | F.control) == .init(trigger: true, others: true))
        #expect(HotkeyKey.command.modifiers(fromFlags: F.command | F.rightCommand) == .init(trigger: true, others: false))
    }

    @Test func rightOptionOnlyMatchesRightSide() {
        #expect(HotkeyKey.rightOption.modifiers(fromFlags: F.option | F.rightOption) == .init(trigger: true, others: false))
        // 只按左 Option 不触发
        #expect(HotkeyKey.rightOption.modifiers(fromFlags: F.option | F.leftOption) == .init(trigger: false, others: true))
        // 左右一起按算作按了别的键
        #expect(HotkeyKey.rightOption.modifiers(fromFlags: F.option | F.leftOption | F.rightOption)
            == .init(trigger: true, others: true))
    }

    @Test func rightCommandOnlyMatchesRightSide() {
        #expect(HotkeyKey.rightCommand.modifiers(fromFlags: F.command | F.rightCommand) == .init(trigger: true, others: false))
        #expect(HotkeyKey.rightCommand.modifiers(fromFlags: F.command | F.leftCommand).trigger == false)
    }

    @Test func optionCommandNeedsBoth() {
        let key = HotkeyKey.optionCommand
        #expect(key.modifiers(fromFlags: F.option) == .init(trigger: false, others: false))
        #expect(key.modifiers(fromFlags: F.command) == .init(trigger: false, others: false))
        #expect(key.modifiers(fromFlags: F.option | F.command) == .init(trigger: true, others: false))
        #expect(key.modifiers(fromFlags: F.option | F.command | F.shift) == .init(trigger: true, others: true))
        // 只按 Command 时，以 Control 为触发键的判断不受影响
        #expect(HotkeyKey.control.modifiers(fromFlags: F.option | F.command).trigger == false)
    }

    @Test func fn() {
        #expect(HotkeyKey.fn.modifiers(fromFlags: F.fn) == .init(trigger: true, others: false))
        #expect(HotkeyKey.fn.modifiers(fromFlags: F.fn | F.command) == .init(trigger: true, others: true))
        // 以 Control 为触发键时，Fn 算作别的键
        #expect(HotkeyKey.control.modifiers(fromFlags: F.control | F.fn).others)
    }
}

@Suite struct NewSettingsConfigTests {
    @Test func defaults() throws {
        let config = try AppConfig.decode(Data("{}".utf8))
        #expect(config.hotkey == .optionCommand)
        #expect(config.microphone == "")
        #expect(config.history)
    }

    @Test func roundTrip() throws {
        let config = AppConfig(hotkey: .rightOption, microphone: "BuiltInMicrophoneDevice", history: false)
        #expect(try AppConfig.decode(config.encode()) == config)
        #expect(try AppConfig.decode(Data(#"{"hotkey": "caps_lock"}"#.utf8)).hotkey == .optionCommand)
    }
}
