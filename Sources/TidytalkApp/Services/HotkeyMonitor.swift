import AppKit
import TidytalkCore

/// 通过 CGEventTap 监听全局按键（需要辅助功能权限），驱动 `HotkeyStateMachine`。
///
/// 只监听、不拦截（listen-only）：系统不会等待这里处理完才把按键交给其他应用，
/// 即使主线程卡住或辅助功能权限被收回，也不会卡住全局的键盘和鼠标。
@MainActor
final class HotkeyMonitor {
    nonisolated static let holdDelay: TimeInterval = 0.4
    /// 自己合成的事件（例如 Cmd+V）带上这个标记，监听时忽略。
    nonisolated static let syntheticEventMarker: Int64 = 0x7469_6479 // "tidy"
    nonisolated static let escapeKeyCode: Int64 = 53
    /// 按住录音期间多久核对一次真实按键状态，足够快地发现漏掉的松开事件，又不占 CPU。
    nonisolated static let releaseCheckInterval: TimeInterval = 0.25
    /// 多久检查一次辅助功能权限是否被收回；收回后事件监听会失效，要及时停下。
    nonisolated static let trustCheckInterval: TimeInterval = 1

    /// 两种用途的触发键：说话输入，以及语音改写选中的文字。
    enum Purpose { case dictation, rewrite }

    var onAction: ((HotkeyStateMachine.Action, Purpose) -> Void)?
    /// 辅助功能权限被收回、监听已自动停止时调用。
    var onPermissionLost: (() -> Void)?
    /// 说话输入的触发键，每次处理事件时读取，修改设置后立即生效。
    var dictationKey: () -> HotkeyKey = { .optionCommand }
    /// 语音改写的触发键，nil 表示关闭。
    var rewriteKey: () -> HotkeyKey? = { nil }
    /// 是否允许双击触发键进入免按住录音（只用于说话输入）。
    var handsFreeEnabled: () -> Bool = { false }

    private let dictation = Channel(purpose: .dictation)
    private let rewrite = Channel(purpose: .rewrite)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 监听期间定期确认辅助功能权限还在。
    private var trustWatchdog: Timer?

    var isRunning: Bool { tap != nil }

    init() {
        for channel in [dictation, rewrite] {
            channel.onAction = { [weak self] action, purpose in self?.onAction?(action, purpose) }
        }
        dictation.key = { [weak self] in self?.dictationKey() }
        rewrite.key = { [weak self] in self?.rewriteKey() }
    }

    /// 创建事件监听。没有辅助功能权限时返回 false。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.accessibility else { return false }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        startTrustWatchdog()
        return true
    }

    /// 移除事件监听。权限被收回后必须移除，不能反复重新启用。
    func stop() {
        trustWatchdog?.invalidate()
        trustWatchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        // 取消可能还在进行的录音：免按住录音时触发键本来就是松开的，单靠"松开"结束不了，
        // 监听停了以后 Esc 也收不到，麦克风会一直开到时长上限
        dictation.dispatch(.reset)
        rewrite.dispatch(.reset)
    }

    private func startTrustWatchdog() {
        trustWatchdog?.invalidate()
        let timer = Timer(timeInterval: Self.trustCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stopIfPermissionLost() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustWatchdog = timer
    }

    /// 返回 true 表示权限已被收回并已停止监听。
    @discardableResult
    private func stopIfPermissionLost() -> Bool {
        guard tap != nil, !Permissions.accessibility else { return false }
        stop()
        onPermissionLost?()
        return true
    }

    /// 录音在外部结束（时长上限、启动失败等），本次按键作废，等待触发键松开。
    func recordingEndedExternally(_ purpose: Purpose) {
        channel(purpose).dispatch(.recordingEndedExternally)
    }

    /// 没在录音时按下 Esc。
    var onEscapeWhileIdle: (() -> Void)?

    /// 从应用外部开始或结束说话输入（tidytalk://toggle），按免按住录音处理。
    func externalToggle() {
        dictation.dispatch(.externalToggle)
    }

    /// 从应用外部取消正在进行的录音（tidytalk://cancel），和按 Esc 一样。
    func externalCancel() {
        dictation.dispatch(.escapeDown)
        rewrite.dispatch(.escapeDown)
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags, keyCode: Int64, isSynthetic: Bool) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 权限被收回时系统会停用监听，这时不能再重新启用
            if stopIfPermissionLost() { return }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let current = CGEventSource.flagsState(.combinedSessionState)
            dictation.sync(current)
            rewrite.sync(current)
            return
        default:
            break
        }

        if isSynthetic { return }
        dictation.machine.handsFreeEnabled = handsFreeEnabled()

        // 没在录音时按 Esc：交给调用方取消正在进行的处理（例如还在等 AI）
        if type == .keyDown, keyCode == Self.escapeKeyCode,
           dictation.machine.state == .idle, rewrite.machine.state == .idle {
            onEscapeWhileIdle?()
        }

        let event: HotkeyStateMachine.Event?
        switch type {
        case .flagsChanged:
            dictation.sync(flags)
            rewrite.sync(flags)
            return
        case .keyDown:
            event = keyCode == Self.escapeKeyCode ? .escapeDown : .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            event = .mouseDown
        default:
            event = nil
        }
        if let event {
            dictation.dispatch(event)
            rewrite.dispatch(event)
        }
    }

    private func channel(_ purpose: Purpose) -> Channel {
        purpose == .dictation ? dictation : rewrite
    }
}

/// 一个触发键对应的状态机、保持计时器和松开检查。
@MainActor
private final class Channel {
    let purpose: HotkeyMonitor.Purpose
    var machine = HotkeyStateMachine()
    var key: () -> HotkeyKey? = { nil }
    var onAction: ((HotkeyStateMachine.Action, HotkeyMonitor.Purpose) -> Void)?
    private var holdTimer: Timer?
    private var releaseWatchdog: Timer?

    init(purpose: HotkeyMonitor.Purpose) {
        self.purpose = purpose
    }

    func sync(_ flags: CGEventFlags) {
        guard let key = key() else {
            // 触发键被关闭：结束可能还在进行的录音
            if machine.state != .idle { dispatch(.modifiersChanged(.init(trigger: false, others: false))) }
            return
        }
        dispatch(.modifiersChanged(key.modifiers(fromFlags: flags.rawValue)))
    }

    func dispatch(_ event: HotkeyStateMachine.Event) {
        for action in machine.handle(event, at: ProcessInfo.processInfo.systemUptime) {
            switch action {
            case .scheduleHoldTimer:
                scheduleHoldTimer()
            case .cancelHoldTimer:
                holdTimer?.invalidate()
                holdTimer = nil
            case .startRecording:
                // 免按住录音期间触发键本来就是松开的，不需要检查
                if machine.state == .recording { startWatchdog() }
                onAction?(action, purpose)
            case .finishRecording, .cancelRecording:
                stopWatchdog()
                onAction?(action, purpose)
            }
        }
        if machine.state != .recording { stopWatchdog() }
    }

    private func scheduleHoldTimer() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: HotkeyMonitor.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.holdTimer = nil
                self?.dispatch(.holdTimerFired)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// 按住录音期间定期核对真实按键状态，防止漏掉松开事件导致一直录音。
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: HotkeyMonitor.releaseCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.key() else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if !key.modifiers(fromFlags: flags.rawValue).trigger { self.sync(flags) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatchdog = timer
    }

    private func stopWatchdog() {
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticEventMarker
        // 事件源添加在主线程的 run loop 上
        MainActor.assumeIsolated {
            monitor.handle(type: type, flags: flags, keyCode: keyCode, isSynthetic: isSynthetic)
        }
    }
    return Unmanaged.passUnretained(event)
}
