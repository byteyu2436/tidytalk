import AppKit

/// 应用入口。可执行目标 `Tidytalk` 的 main.swift 只调用 `run()`；
/// 其余代码都在这个库里，单元测试（TidytalkAppTests）可以直接测试。
public enum Launch {
    /// 处理开发命令和命令行参数，然后启动菜单栏应用。必须在主线程上调用，不会返回。
    public static func run() -> Never {
        #if DEBUG || TIDYTALK_DEV_TOOLS
        if DebugCommands.runIfRequested() { exit(0) }
        // 开发用：`open -n Tidytalk.app --args --focus-check <文件>`，把当前焦点是否可输入写入文件
        if let i = CommandLine.arguments.firstIndex(of: "--focus-check"), i + 1 < CommandLine.arguments.count {
            let report = MainActor.assumeIsolated { FocusInspector.describeFocus() }
            try? (report + "\n").write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        // 开发用：列出麦克风
        if CommandLine.arguments.contains("--list-mics") {
            for device in AudioDevices.inputDevices() { print("\(device.name)\t\(device.uid)") }
            exit(0)
        }
        // 开发用：`open -n Tidytalk.app --args --check-permissions <文件>`，把权限状态写入文件；不带文件时输出到终端
        if let i = CommandLine.arguments.firstIndex(of: "--check-permissions") {
            let line = "accessibility=\(Permissions.accessibility) microphone=\(Permissions.microphone)\n"
            if i + 1 < CommandLine.arguments.count {
                try? line.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            } else {
                print(line, terminator: "")
            }
            exit(0)
        }
        if MainActor.assumeIsolated({ SnapshotCommand.runIfRequested() || DownloadCommand.runIfRequested() || RecordTestCommand.runIfRequested() || IndicatorCaptureCommand.runIfRequested() || SettingsCaptureCommand.runIfRequested() || MenuDumpCommand.runIfRequested() || OnboardingCaptureCommand.runIfRequested() || ListenTestCommand.runIfRequested() || CaptionCaptureCommand.runIfRequested() || SiteCaptionCaptureCommand.runIfRequested() || TranscribeTestCommand.runIfRequested() || MeetingTestCommand.runIfRequested() || MainWindowCaptureCommand.runIfRequested() }) { exit(0) }
        #endif

        // 不认识的 -- 参数（包括正式版里没有的开发命令）：直接退出，不启动应用，以免在终端下多开一份
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
            FileHandle.standardError.write(Data("未知参数：\(CommandLine.arguments.dropFirst().joined(separator: " "))\n".utf8))
            exit(2)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            // 不在 Dock 中显示（打包后由 Info.plist 的 LSUIElement 决定，这里保证 `swift run` 时一致）
            app.setActivationPolicy(.accessory)
            app.run()
        }
        exit(0)
    }
}
