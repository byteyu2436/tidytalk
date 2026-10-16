import Carbon.HIToolbox
import Foundation

/// 系统级快捷键（Carbon `RegisterEventHotKey`），例如 ⌃⌥C 开关实时字幕。
///
/// 不需要辅助功能权限；按下时只有本应用收到，不会再传给当前应用。
@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: 虚拟键码，例如 `kVK_ANSI_C`。
    ///   - modifiers: Carbon 修饰键，例如 `controlKey | optionKey`。
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_4B59), id: id) // 'TTKY'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon 事件在主线程上分发
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
