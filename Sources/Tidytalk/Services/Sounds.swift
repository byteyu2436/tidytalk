import AppKit

/// 开始、结束录音的提示音，使用系统自带的声音。
@MainActor
enum Sounds {
    static func start() { play("Tink") }
    static func finish() { play("Pop") }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.volume = 0.35
        sound.play()
    }
}
