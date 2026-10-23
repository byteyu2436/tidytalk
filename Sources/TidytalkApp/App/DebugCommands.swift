// 开发工具只在调试构建，或用 DEV_TOOLS=1 scripts/build-app.sh 打包时编译；
// 发给用户的正式版里没有这些命令。
#if DEBUG || TIDYTALK_DEV_TOOLS
import AVFoundation
import Foundation
import TidytalkCore

/// 开发用命令行入口，不启动界面：
///
///     Tidytalk --transcribe <音频文件> [--cleanup] [--style standard|casual|formal|code]
///              [--vocab 词1,词2] [--replace 错词=正词,错词2=正词2] [--lang en|ja|zh-Hans|…]
///     Tidytalk --cleanup-text <文字> [同上的 --style / --vocab / --replace / --lang] [--level light|standard|thorough]
///              [--rules 规则1|规则2] [--base-url 接口地址] [--model 模型名]
///     Tidytalk --rewrite-text <选中的文字> --instruction <修改要求>
///     Tidytalk --update-feed <JSON 地址> [--current 0.1.0]
///
/// 用已下载的模型识别音频文件；加上 `--cleanup` 时再按 `~/.tidytalk.json` 的配置调用 AI 整理。
enum DebugCommands {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--cleanup-text"), index + 1 < args.count {
            let text = args[index + 1]
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await cleanup(text)
                done.signal()
            }
            done.wait()
            return true
        }
        // 开发用：--incremental-test <音频文件> [--model qwen3_asr]，按真实时间模拟边录边识别，
        // 比较结果是否和整段识别一致，以及松开后要等多久
        if let index = args.firstIndex(of: "--incremental-test"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            let speechModel = value(of: "--model").flatMap(SpeechModel.init(rawValue:)) ?? .senseVoice
            let directory = speechModel.spec.map(ModelManager.directory(for:)) ?? URL(fileURLWithPath: "/")
            Task { @MainActor in
                do {
                    let samples = try loadAudio(url)
                    let recognizer = try SpeechRecognizers.load(speechModel, directory: directory, hotwords: [])
                    let seconds = Double(samples.count) / Double(AudioMath.sampleRate)
                    var start = Date()
                    let whole = await recognizer.transcribe(samples)
                    let wholeWait = Date().timeIntervalSince(start)

                    // 和应用里一样：录音按真实时间增长，每 0.6 秒先切下确定的片段，再刷新一次预览
                    let session = LiveTranscription(recognizer: recognizer, maxSeconds: speechModel.chunkSeconds)
                    let recordingStart = Date()
                    var recorded = 0
                    let fetch: (Int) -> [Float] = { offset in
                        offset < recorded ? Array(samples[offset..<recorded]) : []
                    }
                    var previews = 0
                    while recorded < samples.count {
                        try? await Task.sleep(for: .seconds(0.6))
                        recorded = min(samples.count,
                                       Int(Date().timeIntervalSince(recordingStart) * Double(AudioMath.sampleRate)))
                        session.commit(fetch: fetch)
                        if await session.preview(fetch: fetch) != nil { previews += 1 }
                    }
                    print("录音期间刷新预览 \(previews) 次")
                    start = Date()
                    let incremental = await session.finish(with: samples)
                    let incrementalWait = Date().timeIntervalSince(start)
                    print("模型 \(speechModel.rawValue)，录音 \(String(format: "%.1f", seconds)) 秒")
                    print("整段识别：松开后等 \(String(format: "%.2f", wholeWait)) 秒")
                    print("边录边识别：松开后等 \(String(format: "%.2f", incrementalWait)) 秒")
                    print("结果一致：\(whole == incremental ? "是" : "否")")
                    if whole != incremental { print("整段：\(whole)\n边录：\(incremental)") }
                } catch {
                    print("失败：\(error.localizedDescription)")
                }
                exit(0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(600))
            return true
        }
        if let index = args.firstIndex(of: "--rewrite-text"), index + 1 < args.count,
           let instruction = value(of: "--instruction") {
            let selection = args[index + 1]
            run {
                do {
                    var config = try ConfigStore.read()
                    config.customRules += value(of: "--rules")?.components(separatedBy: "|") ?? []
                    let output = try await ChatCompletionClient(config: config.ai)
                        .rewrite(selection: selection, instruction: instruction, vocabulary: config.vocabulary,
                                 rules: config.customRules)
                    print("改写结果：\(RewritePrompt.validate(selection: selection, rewritten: output) ?? "（校验未通过）\(output)")")
                } catch {
                    print("失败：\(error.localizedDescription)")
                }
            }
            return true
        }
        if let feed = value(of: "--update-feed").flatMap(URL.init(string:)) {
            run {
                do {
                    guard let release = try await UpdateChecker.fetchLatest(from: feed) else {
                        print("还没有发布任何版本")
                        return
                    }
                    let current = value(of: "--current") ?? "0.1.0"
                    print("最新 \(release.version)，当前 \(current)，需要更新：\(AppVersion.isNewer(release.version, than: current))，下载：\(release.url)")
                } catch {
                    print("失败：\(error.localizedDescription)")
                }
            }
            return true
        }
        // 模拟边说边预览：把音频按 0.6 秒一段逐步喂给录音期间的识别，打印每次的预览文字和耗时
        if let index = args.firstIndex(of: "--preview-sim"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            Task { @MainActor in
                do {
                    let samples = try loadAudio(url)
                    let recognizer = try SpeechRecognizer(model: .senseVoice,
                                                          directory: ModelManager.directory(for: .senseVoice))
                    let session = LiveTranscription(recognizer: recognizer, maxSeconds: SpeechModel.senseVoice.chunkSeconds)
                    let step = Int(0.6 * Double(AudioMath.sampleRate))
                    var end = 0
                    var slowest = 0.0
                    let fetch: (Int) -> [Float] = { offset in offset < end ? Array(samples[offset..<end]) : [] }
                    while end < samples.count {
                        end = min(samples.count, end + step)
                        let start = Date()
                        session.commit(fetch: fetch)
                        let text = await session.preview(fetch: fetch)
                        let cost = Date().timeIntervalSince(start)
                        slowest = max(slowest, cost)
                        if let text {
                            let seconds = Double(end) / Double(AudioMath.sampleRate)
                            print(String(format: "%5.1f 秒 耗时 %.2f 秒：", seconds, cost) + String(text.suffix(30)))
                        }
                    }
                    print(String(format: "最慢一次 %.2f 秒", slowest))
                } catch {
                    print("失败：\(error.localizedDescription)")
                }
                exit(0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(600))
            return true
        }
        guard let index = args.firstIndex(of: "--transcribe"), index + 1 < args.count else { return false }
        let url = URL(fileURLWithPath: args[index + 1])
        let cleanup = args.contains("--cleanup")

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await transcribe(url, cleanup: cleanup)
            done.signal()
        }
        done.wait()
        return true
    }

    private static func transcribe(_ url: URL, cleanup: Bool) async {
        // 开发用：`--model qwen3_asr` 等指定识别模型，默认 SenseVoice
        let speechModel = value(of: "--model").flatMap(SpeechModel.init(rawValue:)) ?? .senseVoice
        let directory = speechModel.spec.map(ModelManager.directory(for:)) ?? URL(fileURLWithPath: "/")
        do {
            let samples = try loadAudio(url)
            print("音频时长：\(String(format: "%.1f", Double(samples.count) / Double(AudioMath.sampleRate))) 秒")

            var start = Date()
            // 开发用：`--hotwords 词1,词2` 作为热词
            let hotwords = value(of: "--hotwords")?.components(separatedBy: ",") ?? []
            let recognizer = try SpeechRecognizers.load(speechModel, directory: directory, hotwords: hotwords)
            print("模型：\(speechModel.title)")
            print("模型加载：\(String(format: "%.2f", Date().timeIntervalSince(start))) 秒")

            start = Date()
            let text = await recognizer.transcribe(samples)
            print("识别耗时：\(String(format: "%.2f", Date().timeIntervalSince(start))) 秒")
            print("识别结果：\(text)")

            guard cleanup else { return }
            await Self.cleanup(text)
        } catch {
            print("失败：\(error.localizedDescription)")
        }
    }

    /// 按配置（可用 --style / --vocab / --replace 临时调整）整理一段文字并打印结果。
    private static func cleanup(_ text: String) async {
        do {
            var config = try ConfigStore.read()
            // 临时追加词库和替换规则，不改动配置文件
            config.vocabulary += value(of: "--vocab")?.components(separatedBy: ",") ?? []
            config.customRules += value(of: "--rules")?.components(separatedBy: "|") ?? []
            for rule in value(of: "--replace")?.components(separatedBy: ",") ?? [] {
                let parts = rule.components(separatedBy: "=")
                if parts.count == 2 { config.replacements[parts[0]] = parts[1] }
            }
            // 临时换接口，例如测试本机模型：--base-url http://localhost:11434/v1 --model qwen2.5:7b
            if let url = value(of: "--base-url") { config.ai.baseURL = url }
            if let model = value(of: "--model") { config.ai.model = model }
            let style = style() ?? config.style
            let language = value(of: "--lang").flatMap(OutputLanguage.init(rawValue:)) ?? config.outputLanguage
            let level = value(of: "--level").flatMap(CleanupLevel.init(rawValue:)) ?? config.cleanupLevel
            let prepared = TextPipeline.prepare(text, config: config)
            if prepared != text { print("替换后：\(prepared)") }
            guard config.ai.isConfigured else {
                print("~/.tidytalk.json 中的 AI 配置不完整")
                return
            }
            let start = Date()
            let output = try await ChatCompletionClient(config: config.ai)
                .cleanup(prepared, style: style, vocabulary: config.vocabulary, language: language, level: level,
                         rules: config.customRules)
            print("整理耗时（\(level.title)，\(style.title)，\(language.title)）：\(String(format: "%.2f", Date().timeIntervalSince(start))) 秒")
            if let valid = TranscriptCleanup.validate(raw: prepared, cleaned: output, language: language, level: level,
                                                      vocabulary: config.vocabulary) {
                print("整理结果：\(TextPipeline.finish(valid, config: config, style: style, language: language))")
            } else {
                print("整理结果异常，回退原文。模型输出：\(output)")
            }
        } catch {
            print("失败：\(error.localizedDescription)")
        }
    }

    private static func run(_ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            done.signal()
        }
        done.wait()
    }

    private static func style() -> CleanupStyle? {
        value(of: "--style").flatMap(CleanupStyle.init(rawValue:))
    }

    private static func value(of flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 读取任意格式的音频并转换为 16 kHz 单声道。
    private static func loadAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioMath.sampleRate),
                                   channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return [] }
        try file.read(into: input)

        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

import AppKit
import SwiftUI

/// 开发用：把界面离屏渲染成 PNG，便于在没有屏幕录制权限时检查布局。
///
///     Tidytalk --snapshot <输出目录>
@MainActor
enum SnapshotCommand {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let model = AppModel()
        render(OnboardingView(model: model, onFinish: {}), to: dir.appending(path: "onboarding.png"))
        render(GeneralSettings(model: model).frame(width: 560, height: 640), to: dir.appending(path: "settings.png"))
        // 完整高度，检查下半部分的文字
        render(GeneralSettings(model: model).frame(width: 560, height: 2200), to: dir.appending(path: "settings-full.png"))
        render(AIConfigEditor(model: model).padding(24).frame(width: 400), to: dir.appending(path: "ai-config.png"))
        render(VocabularySettings(model: model).frame(width: 560, height: 620), to: dir.appending(path: "vocabulary.png"))

        let phases: [(String, AppModel.Phase)] = [
            ("indicator-recording", .recording),
            ("indicator-processing", .processing),
            ("indicator-message", .message("整理失败，已粘贴原文")),
        ]
        for (name, phase) in phases {
            model.phase = phase
            for level in [0.2, 0.9, 0.5, 0.7, 0.3, 1.0, 0.6] as [Float] { model.pushLevel(level) }
            render(IndicatorView(model: model).frame(width: 420, height: 96).background(Color.gray.opacity(0.3)),
                   to: dir.appending(path: "\(name).png"))
        }
        return true
    }

    private static func render(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("已保存 \(url.path)（\(Int(size.width))×\(Int(size.height))）")
    }
}

/// 开发用：不启动界面直接下载模型。
///
///     Tidytalk --download-model
@MainActor
enum DownloadCommand {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--download-model") else { return false }
        // 开发用：`--download-model qwen3_asr` 下载指定的模型，默认 SenseVoice
        let speechModel = index + 1 < args.count ? SpeechModel(rawValue: args[index + 1]) ?? .senseVoice : .senseVoice
        let manager = ModelManager(model: speechModel)
        manager.download()
        var lastPrinted = ""
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let line = "\(manager.status)"
            if line != lastPrinted {
                print(line)
                lastPrinted = line
            }
            switch manager.status {
            case .ready, .failed: return true
            default: continue
            }
        }
    }
}

/// 开发用：真实录音 1.5 秒后把结果写入文件，检查录音链路（需从应用包启动以获得麦克风权限）。
///
///     open -n Tidytalk.app --args --record-test <输出文件> [--device <麦克风 UID>]
@MainActor
enum RecordTestCommand {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--record-test"), index + 1 < args.count else { return false }
        let recorder = AudioRecorder()
        let deviceUID = args.firstIndex(of: "--device").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        var levelCallbacks = 0
        var maxLevel: Float = 0
        recorder.onLevel = { level in
            levelCallbacks += 1
            maxLevel = max(maxLevel, level)
        }
        var line: String
        do {
            try recorder.start(deviceUID: deviceUID)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let samples = recorder.stop()
            line = "ok samples=\(samples.count) seconds=\(Double(samples.count) / Double(AudioMath.sampleRate)) "
                + "levelCallbacks=\(levelCallbacks) maxLevel=\(maxLevel) "
                + "rms=\(AudioMath.rms(samples)) peak=\(samples.map(abs).max() ?? 0)\n"
        } catch {
            line = "error \(error.localizedDescription)\n"
        }
        try? line.write(toFile: args[index + 1], atomically: true, encoding: .utf8)
        return true
    }
}

/// 开发用：把真实的指示器放在彩色背景前，依次切换状态并截图（只截本进程窗口，无需屏幕录制权限）。
///
///     Tidytalk --indicator-capture <输出目录>
@MainActor
enum IndicatorCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--indicator-capture"), index + 1 < args.count,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // 指示器位于鼠标所在屏幕底部，在它后面铺一块彩色条纹窗口
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let backdropFrame = NSRect(x: screen.visibleFrame.midX - 400, y: screen.visibleFrame.minY,
                                   width: 800, height: 220)
        let backdrop = NSWindow(contentRect: backdropFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = StripesView()
        backdrop.level = .floating
        backdrop.orderFrontRegardless()

        let model = AppModel()
        let indicator = IndicatorPanel(model: model)
        let phases: [(String, AppModel.Phase, String?)] = [
            ("recording", .recording, nil), ("processing", .processing, nil),
            ("message", .message("整理失败，已粘贴原文"), nil),
            ("recording-tag", .recording, OutputLanguage.english.indicatorTag), ("rewrite", .recording, "改写"),
        ]
        let previews = [
            "preview-short": "我想问一下这个 API 的 rate limit 是多少",
            "preview-long": "今天下午的会议主要讨论了三件事情，第一件事是下一个版本的发布时间，大家觉得原定的下周三有点赶，最后决定推迟到下周四",
        ]
        let allPhases = phases + [("preview-short", AppModel.Phase.recording, String(localized: "整理")),
                                  ("preview-long", AppModel.Phase.recording, String(localized: "整理"))]
        for (name, phase, tag) in allPhases {
            model.indicatorTag = tag
            model.sparkles = name == "rewrite"
            model.livePreview = previews[name] ?? ""
            model.showsLivePreview = previews[name] != nil
            model.phase = phase
            for level in [0.3, 0.8, 0.5, 1.0, 0.6, 0.9, 0.4] as [Float] { model.pushLevel(level) }
            indicator.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rect = CGRect(x: backdropFrame.minX, y: NSScreen.screens[0].frame.maxY - backdropFrame.maxY,
                              width: backdropFrame.width, height: backdropFrame.height)
            if let image = capture(rect, 1, 0, 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "\(name).png"))
            }
        }

        // 再换成白色文档背景截一张（带实时文字）
        model.livePreview = previews["preview-long"] ?? ""
        model.showsLivePreview = true
        backdrop.contentView = DocumentView()
        model.phase = .recording
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let rect = CGRect(x: backdropFrame.minX, y: NSScreen.screens[0].frame.maxY - backdropFrame.maxY,
                          width: backdropFrame.width, height: backdropFrame.height)
        if let image = capture(rect, 1, 0, 0)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appending(path: "recording-white.png"))
        }
        // 连续几帧，查看光点的运动
        for frame in 1...4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            if let image = capture(rect, 1, 0, 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "frame-\(frame).png"))
            }
        }
        return true
    }

    private final class DocumentView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            let text = NSAttributedString(string: "这是一段普通文档里的文字，用来模拟白色背景的应用窗口。Tidytalk", attributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray,
            ])
            for y in stride(from: 6, to: bounds.height, by: 28) { text.draw(at: NSPoint(x: 120, y: y)) }
        }
    }

    private final class StripesView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for i in 0..<40 {
                colors[i % colors.count].setFill()
                NSRect(x: CGFloat(i) * 22, y: 0, width: 22, height: bounds.height).fill()
            }
            let text = NSAttributedString(string: "Tidytalk 玻璃测试 GLASS TEST", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black,
            ])
            for y in stride(from: 0, to: bounds.height, by: 46) { text.draw(at: NSPoint(x: 120, y: y)) }
        }
    }
}

/// 开发用：打开真实的设置窗口并截图每个标签页（只截本进程窗口，无需屏幕录制权限）。
///
///     Tidytalk --settings-capture <输出目录>
@MainActor
enum SettingsCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func firstEditableField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = firstEditableField(in: sub) { return found } }
        return nil
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--settings-capture"), index + 1 < args.count,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        let window = SettingsWindow.make(model: AppModel())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guard let tabs = window.contentViewController as? NSTabViewController else { return true }

        // 焦点检查：打开后、手动聚焦输入框后、点击空白处后
        func focus() -> String {
            guard let responder = window.firstResponder else { return "nil" }
            return String(describing: type(of: responder))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        print("打开后焦点：\(focus())")
        if let field = firstEditableField(in: window.contentView) {
            window.makeFirstResponder(field)
            print("聚焦输入框后：\(focus())")
            // 在窗口左下角附近（表单空白处）模拟一次点击
            let point = NSPoint(x: 20, y: 20)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            print("点击空白处后：\(focus())")
        }

        for i in tabs.tabViewItems.indices {
            tabs.selectedTabViewItemIndex = i
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            print("标签页 \(i)：\(tabs.tabViewItems[i].label) 窗口内容 \(window.contentLayoutRect.size)")
            // kCGWindowListOptionIncludingWindow，带窗口阴影
            if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "settings-tab\(i).png"))
            }
        }
        return true
    }
}

/// 开发用：打印菜单栏菜单和几条带变量的提示文字，检查翻译（配合 -AppleLanguages "(en)"）。
///
///     Tidytalk --menu-dump -AppleLanguages "(en)" -NSShowNonLocalizedStrings YES
@MainActor
enum MenuDumpCommand {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--menu-dump") else { return false }
        _ = NSApplication.shared
        let model = AppModel()
        model.recordHistory(HistoryEntry(date: Date(), transcript: "嗯我们用克劳德", output: "我们用 Claude。"))
        let controller = StatusItemController(model: model)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        func dump(_ menu: NSMenu, _ indent: String) {
            for item in menu.items where !item.isSeparatorItem {
                print(indent + item.title)
                if let sub = item.submenu { dump(sub, indent + "    ") }
            }
        }
        dump(menu, "")
        print("---")
        print(model.readinessDescription)
        print(ChatCompletionClient.ClientError.http(500, "busy").localizedDescription)
        print(ChatCompletionClient.ClientError.http(404, nil).localizedDescription)
        print(DownloadError.http(503).localizedDescription)
        print(String(localized: "改写：\("make it formal")"))
        print(String(localized: "当前版本 \("0.1.0")。"))
        for level in CleanupLevel.allCases { print(level.title, "-", level.summary) }
        for style in CleanupStyle.allCases { print(style.title, "-", style.summary) }
        for language in OutputLanguage.allCases { print(language.title, "/", language.indicatorTag ?? "-") }
        for key in HotkeyKey.allCases { print(key.title, "/", key.shortName) }
        return true
    }
}


/// 开发用：打开真实的引导窗口并截图每一步（只截本进程窗口）。
///
///     Tidytalk --onboarding-capture <输出目录>
@MainActor
enum OnboardingCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--onboarding-capture"), index + 1 < args.count,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let model = AppModel()
        for step in OnboardingView.Step.allCases {
            let window = AppDelegate.makeOnboardingWindow(model: model, step: step)
            window.center()
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "onboarding-\(step.rawValue).png"))
            }
            window.close()
        }
        return true
    }
}

/// 开发用：收听电脑声音若干秒，把电平和实时字幕的变化写入文件，检查收听链路。
/// 来源读取配置文件的 listen_source，可以配合 `--config <临时配置>` 指定。
///
///     open -n Tidytalk.app --args --listen-test <输出文件> <秒数> [--config <配置文件>]
@MainActor
enum ListenTestCommand {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--listen-test"), index + 2 < args.count,
              let seconds = Double(args[index + 2])
        else { return false }
        let output = args[index + 1]
        var log: [String] = []
        let started = Date()
        func note(_ line: String) {
            log.append(String(format: "%6.2f ", Date().timeIntervalSince(started)) + line)
            try? (log.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        }

        let model = AppModel()
        note("source=\(model.configStore.config.listenSource.isEmpty ? "all" : model.configStore.config.listenSource) "
             + "playing=\(AudioProcesses.playingApps().map(\.bundleID))")

        // 第一阶段：只收音 2 秒，看有没有声音（没有允许"录制系统音频"时全是 0）
        let peak = PeakMeter()
        let raw = SystemAudioCapture { samples in peak.add(samples) }
        if !args.contains("--skip-raw") { do {
            try raw.start(appBundleID: model.configStore.config.listenSource)
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            raw.stop()
            note("raw samples=\(peak.count) peak=\(peak.peak)")
        } catch {
            note("raw error \(error)")
        } }

        // 第二阶段：完整链路
        nonisolated(unsafe) var loaded: (any SpeechTranscribing)?
        let controller = ListenController(model: model) {
            if loaded == nil {
                loaded = try? SpeechRecognizers.load(model.configStore.config.speechModel,
                                                     directory: model.models.directory, hotwords: [])
            }
            return loaded
        }
        controller.onError = { note("error \($0)") }
        controller.onDebug = { note($0) }
        controller.onPaste = { note("paste: \($0)") }
        controller.start()
        note("listening=\(model.isListening)")
        var last = ""
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let text = model.captions.sentences.map { $0.text + ($0.translation.map { " [\($0)]" } ?? "") }.joined(separator: " | ") + " ~ " + model.captions.partial
                + (model.captions.partialTranslation.isEmpty ? "" : " [\(model.captions.partialTranslation)]")
            if text != last {
                note(text)
                last = text
            }
        }
        // 结束前取一次"刚才那段"，只写进日志，不真的粘贴
        if args.contains("--paste") { controller.pasteRecent() }
        controller.stop()
        note("done")
        return true
    }

    private final class PeakMeter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var peak: Float = 0

        func add(_ samples: [Float]) {
            lock.lock()
            count += samples.count
            peak = max(peak, samples.map(abs).max() ?? 0)
            lock.unlock()
        }
    }
}

/// 开发用：把字幕条放在模拟的视频画面和白色文档前截图（只截本进程窗口，无需屏幕录制权限）。
/// 会修改配置里的字幕大小，务必配合 `--config <临时配置>` 使用。
///
///     open -n Tidytalk.app --args --caption-capture <输出目录> --config <临时配置>
@MainActor
enum CaptionCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--caption-capture"), index + 1 < args.count,
              args.contains("--config"),
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.removeObject(forKey: "captionPanelOrigin")

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let backdropFrame = NSRect(x: screen.visibleFrame.midX - 450, y: screen.visibleFrame.minY + 60,
                                   width: 900, height: 260)
        let backdrop = NSWindow(contentRect: backdropFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = VideoView()
        backdrop.level = .floating
        backdrop.orderFrontRegardless()

        let model = AppModel()
        model.configStore.update { $0.captionSize = .medium }
        let panel = CaptionPanel(model: model)
        model.isListening = true
        panel.show()

        func shot(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let rect = CGRect(x: backdropFrame.minX, y: NSScreen.screens[0].frame.maxY - backdropFrame.maxY,
                              width: backdropFrame.width, height: backdropFrame.height)
            if let image = capture(rect, 1, 0, 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "\(name).png"))
            }
        }

        shot("listening")
        model.captions.commit("Good morning everyone. Today we will review the quarterly results.")
        model.captions.partial = "Then we will talk about the plan"
        shot("english")
        model.captions.clear()
        for sentence in ["大家好，今天我们来讨论一下下个季度的计划。", "首先请产品经理介绍一下新功能，然后设计和开发分别说一下排期。",
                         "这次的重点是实时字幕，可以收听视频和会议里的声音。"] {
            model.captions.commit(sentence)
        }
        model.captions.partial = "大家有什么问题"
        shot("chinese")
        panel.showsControls = true
        shot("controls")
        model.listeningPaused = true
        shot("paused")
        model.listeningPaused = false
        panel.showsControls = false
        for size in [CaptionSize.small, .large] {
            model.configStore.update { $0.captionSize = size }
            shot("size-\(size.rawValue)")
        }
        model.configStore.update { $0.captionSize = .medium }
        backdrop.contentView = DocumentView()
        shot("white")

        // 打开翻译：每句原文下面一行译文
        backdrop.contentView = VideoView()
        model.configStore.update { $0.captionTranslate = true }
        model.captions.clear()
        let pairs = [("Good morning everyone. Today we will review the quarterly results.", "大家早上好，今天我们来回顾一下季度业绩。"),
                     ("Then we will talk about the plan for next year.", "然后我们聊聊明年的计划。")]
        for (original, translation) in pairs {
            if let id = model.captions.commit(original) { model.captions.setTranslation(translation, for: id) }
        }
        shot("bilingual")
        if let id = model.captions.commit("Does anyone have questions before we start?") { model.captions.markTranslating(id) }
        shot("bilingual-translating")
        model.captions.partial = "Okay, let's move on to"
        model.captions.partialTranslation = "好的，我们接下来看看"
        panel.showsControls = true
        shot("bilingual-partial")
        panel.showsControls = false

        // 鼠标停在第二句上的高亮，以及点击换算到的句子
        let ids = model.captions.sentences.map(\.id)
        panel.debugHover(.sentence(ids[ids.count - 1]))
        shot("hover")
        panel.debugHover(nil)
        var clicks: [String] = []
        panel.onPasteFrom = { id in clicks.append(id.map { model.captions.passage(from: $0) } ?? "partial:" + model.captions.passage(from: nil)) }
        // 点句子本身不粘贴；停在句子上后点"粘贴"按钮才粘贴
        panel.debugClick(.sentence(ids[1]), onButton: false)
        panel.debugHover(.sentence(ids[1]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        panel.debugClick(.sentence(ids[1]), onButton: true)
        panel.debugHover(.partial)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        panel.debugClick(.partial, onButton: true)
        panel.debugHover(nil)
        try? clicks.joined(separator: "\n").write(to: dir.appending(path: "clicks.txt"), atomically: true, encoding: .utf8)
        model.configStore.update { $0.captionTranslate = false }

        // 玻璃样式：彩色画面、白色文档，以及系统深色模式下各截一张
        model.captions.clear()
        for sentence in ["大家好，今天我们来讨论一下下个季度的计划。", "首先请产品经理介绍一下新功能。"] { model.captions.commit(sentence) }
        model.captions.partial = "大家有什么问题"
        model.configStore.update { $0.captionStyle = .glass }
        backdrop.contentView = VideoView()
        shot("glass-video-early")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        shot("glass-video")
        backdrop.contentView = DocumentView()
        shot("glass-white")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        backdrop.contentView = VideoView()
        shot("glass-video-dark")
        model.configStore.update { $0.captionTranslate = true }
        model.captions.clear()
        for (original, translation) in pairs {
            if let id = model.captions.commit(original) { model.captions.setTranslation(translation, for: id) }
        }
        panel.showsControls = true
        shot("glass-bilingual-dark")
        NSApp.appearance = nil
        shot("glass-bilingual")
        panel.showsControls = false
        model.configStore.update { $0.captionStyle = .dark; $0.captionTranslate = false }
        return true
    }

    /// 模拟视频画面：明暗不一的色块。
    private final class VideoView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let gradient = NSGradient(colors: [.systemTeal, .systemIndigo, .black, .systemOrange, .white])!
            gradient.draw(in: bounds, angle: 15)
        }
    }

    private final class DocumentView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            let text = NSAttributedString(string: "这是一段普通文档里的文字，用来模拟白色背景的应用窗口。Tidytalk", attributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray,
            ])
            for y in stride(from: 6, to: bounds.height, by: 28) { text.draw(at: NSPoint(x: 120, y: y)) }
        }
    }
}
/// 开发用：官网配图。把真实的字幕条（打开翻译）放在模拟的视频画面上截图，生成 captions-en.png 和 captions-zh.png。
/// 会修改配置，务必配合 `--config <临时配置>` 使用。
///
///     open -n Tidytalk.app --args --site-caption-capture <输出目录> --config <临时配置>
@MainActor
enum SiteCaptionCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--site-caption-capture"), index + 1 < args.count,
              args.contains("--config"),
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // 和官网功能区的配图同样的比例（1000 × 883）
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let size = NSSize(width: 820, height: 724)
        let frame = NSRect(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                           y: screen.visibleFrame.minY + 40, width: size.width, height: size.height)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = SceneView()
        backdrop.level = .floating
        backdrop.orderFrontRegardless()

        let model = AppModel()
        model.configStore.update {
            $0.captionSize = .medium
            $0.captionStyle = .dark
            $0.captionTranslate = true
        }
        // 字幕条放在画面下方，左右居中
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.midX - CaptionPanel.width / 2, y: frame.minY + 44)),
                                  forKey: "captionPanelOrigin")
        let panel = CaptionPanel(model: model)
        model.isListening = true

        let versions: [(String, [(String, String)])] = [
            ("en", [("欢迎回来，今天我们来看看新版本的表现。", "Welcome back. Today we'll look at how the new release performs."),
                    ("启动时间缩短了将近一半。", "Startup time dropped by almost half.")]),
            ("zh", [("Welcome back. Today we'll look at how the new release performs.", "欢迎回来，今天我们来看看新版本的表现。"),
                    ("Startup time dropped by almost half.", "启动时间缩短了将近一半。")]),
        ]
        for (name, pairs) in versions {
            model.captions.clear()
            for (original, translation) in pairs {
                if let id = model.captions.commit(original) { model.captions.setTranslation(translation, for: id) }
            }
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let rect = CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY,
                              width: frame.width, height: frame.height)
            if let image = capture(rect, 1, 0, 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "captions-\(name).png"))
            }
        }
        UserDefaults.standard.removeObject(forKey: "captionPanelOrigin")
        return true
    }

    /// 模拟的视频画面：深色的舞台，几团柔和的灯光。
    private final class SceneView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: 1),
                                NSColor(srgbRed: 0.13, green: 0.12, blue: 0.24, alpha: 1)])!
                .draw(in: bounds, angle: 90)
            let lights: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
                (0.22, 0.72, 260, NSColor(srgbRed: 0.98, green: 0.55, blue: 0.25, alpha: 0.55)),
                (0.78, 0.62, 300, NSColor(srgbRed: 0.35, green: 0.45, blue: 1.0, alpha: 0.5)),
                (0.52, 0.88, 200, NSColor(srgbRed: 0.85, green: 0.35, blue: 0.75, alpha: 0.4)),
            ]
            for (x, y, radius, color) in lights {
                let center = NSPoint(x: bounds.width * x, y: bounds.height * y)
                NSGradient(colors: [color, color.withAlphaComponent(0)])!
                    .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
            }
            // 讲台上的人影
            NSColor(white: 0, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 70, y: bounds.height * 0.42, width: 140, height: 150)).fill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 150, y: -40, width: 300, height: bounds.height * 0.44),
                         xRadius: 120, yRadius: 120).fill()
        }
    }
}
/// 开发用：走和转写窗口相同的流程转写一个文件或链接，把进度和 SRT 结果写入文件。
/// 识别模型读取配置文件的 speech_model，可以配合 `--config <临时配置>` 指定。
///
///     open -n Tidytalk.app --args --transcribe-test <文件或链接> <输出文件> [--config <配置文件>]
@MainActor
enum TranscribeTestCommand {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--transcribe-test"), index + 2 < args.count else { return false }
        let input = args[index + 1], output = args[index + 2]
        var log: [String] = []
        let started = Date()
        func note(_ line: String) {
            log.append(String(format: "%7.2f ", Date().timeIntervalSince(started)) + line)
            try? (log.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        }
        _ = NSApplication.shared
        let model = AppModel()
        let speechModel = model.configStore.config.speechModel
        note("model=\(speechModel.rawValue) ready=\(model.models.isReady)")
        nonisolated(unsafe) var loaded: (any SpeechTranscribing)?
        let controller = TranscribeController(model: model) {
            if loaded == nil {
                let start = Date()
                loaded = try? SpeechRecognizers.load(speechModel, directory: model.models.directory,
                                                     hotwords: model.configStore.config.vocabulary)
                note("load \(loaded == nil ? "failed" : "ok") in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            }
            return loaded
        }
        if !input.hasPrefix("http") {
            // 先单独解码和切句一次，检查采样率和切出的句子
            let url = URL(fileURLWithPath: input)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var info = ""
            Task.detached {
                do {
                    let samples = try await AudioFileDecoder.load(url) { _ in }
                    let pieces = try FileTranscriber.split(samples)
                    info = "decoded \(samples.count) samples = \(Double(samples.count) / 16000)s rms=\(AudioMath.rms(samples)); pieces: "
                        + pieces.map { String(format: "%.2f+%.2f", $0.start, $0.end - $0.start) }.joined(separator: " ")
                } catch {
                    info = "decode error \(error)"
                }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            note(info)
        }
        if input.hasPrefix("http") {
            controller.transcribe(link: input)
        } else {
            controller.transcribe(file: URL(fileURLWithPath: input))
        }
        var last = ""
        let deadline = Date().addingTimeInterval(900)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let stage = "\(controller.stage)"
            if stage != last {
                note(stage)
                last = stage
            }
        } while controller.stage.isBusy && Date() < deadline
        note("title=\(controller.title)")
        note("\n" + TranscriptExport.render(controller.segments, as: .srt))
        return true
    }
}
/// 开发用：打开真实的转写窗口截图：空白状态，以及转写一个文件之后的结果。
///
///     open -n Tidytalk.app --args --transcribe-capture <输出目录> <音频文件> [--config <配置文件>]
@MainActor
enum TranscribeCaptureCommand {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--transcribe-capture"), index + 2 < args.count,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return false }
        let capture = unsafeBitCast(symbol, to: CreateImage.self)
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let model = AppModel()
        nonisolated(unsafe) var loaded: (any SpeechTranscribing)?
        let controller = TranscribeController(model: model) {
            if loaded == nil {
                loaded = try? SpeechRecognizers.load(model.configStore.config.speechModel,
                                                     directory: model.models.directory, hotwords: [])
            }
            return loaded
        }
        let window = TranscribeWindow.make(controller: controller)
        window.makeKeyAndOrderFront(nil)
        func shot(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "\(name).png"))
            }
        }
        shot("transcribe-empty")
        controller.transcribe(file: URL(fileURLWithPath: args[index + 2]))
        let deadline = Date().addingTimeInterval(120)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        } while controller.stage != .finished && Date() < deadline
        shot("transcribe-result")
        return true
    }
}


#endif
