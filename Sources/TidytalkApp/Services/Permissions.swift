import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    enum MicrophoneStatus { case granted, denied, notDetermined }

    static var microphone: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示，并把应用加入列表。
    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// 系统设置 › 隐私与安全性 › 录屏与系统录音 里的"仅系统录音"。
    static func openSystemAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
