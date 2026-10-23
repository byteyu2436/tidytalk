import Foundation
import Security
import Testing
@testable import TidytalkApp
import TidytalkCore

/// 配置文件的读写（docs/review-2026-10.md 的 A1–A5、I1）。
@MainActor
@Suite struct ConfigStoreTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    @Test func a1BrokenFileIsNeverOverwritten() throws {
        let broken = #"{ "cleanup_enabled": true, "ai": { "api_key": "sk-keep" ,,, }"#
        let file = try directory.file("broken.json", contents: broken)
        let store = ConfigStore(fileURL: file, keychain: nil)
        #expect(store.loadError?.contains("格式错误") == true)
        #expect(store.update { $0.cleanupEnabled.toggle() } == false)
        #expect(store.save(AppConfig()) == false)
        #expect(file.text == broken)
    }

    @Test func a2ExternalEditSurvivesToggle() throws {
        let file = try directory.file("config.json", contents: #"{ "vocabulary": ["旧词"] }"#)
        let store = ConfigStore(fileURL: file, keychain: nil)
        // 用户在编辑器里改了文件，内存里的配置还是旧的
        try Data(#"{ "vocabulary": ["刚加的词"] }"#.utf8).write(to: file)
        #expect(store.update { $0.cleanupEnabled.toggle() })
        #expect(file.json["vocabulary"] as? [String] == ["刚加的词"])
    }

    @Test func a3UnreadableFileIsReportedAndKept() throws {
        let file = try directory.file("locked.json", contents: #"{ "cleanup_enabled": false }"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = ConfigStore(fileURL: file, keychain: nil)
        #expect(store.loadError?.contains("无法读取") == true)
        #expect(store.update { $0.cleanupEnabled = true } == false)
        #expect(file.posixPermissions == 0o000)
    }

    @Test func a4NewFileIsOnlyReadableByOwner() throws {
        let file = try directory.file("new.json")
        let store = ConfigStore(fileURL: file, keychain: nil)
        #expect(store.loadError == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(file.posixPermissions == 0o600)
        #expect(store.update { $0.sounds = false })
        #expect(file.posixPermissions == 0o600)
        // 临时文件都已经换成正式文件，目录里没有残留
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["new.json"])
    }

    @Test func a5KeyInFileMovesToKeychain() async throws {
        let file = try directory.file("config.json", contents: #"{ "ai": { "api_key": "sk-from-file" } }"#)
        let backend = FakeKeychainBackend()
        let store = ConfigStore(fileURL: file, keychain: KeychainStore(backend: backend))
        #expect(store.config.ai.apiKey == "sk-from-file")
        #expect(store.update { $0.sounds = false })
        #expect(backend.key == "sk-from-file")
        #expect((file.json["ai"] as? [String: Any])?["api_key"] as? String == "")
        // 重新读取时从钥匙串取回
        store.reload()
        #expect(store.config.ai.apiKey == "sk-from-file")
    }

    @Test func a5KeychainIsReadInBackgroundOnLaunch() async throws {
        let file = try directory.file("config.json", contents: #"{ "ai": { "api_key": "" } }"#)
        let store = ConfigStore(fileURL: file, keychain: KeychainStore(backend: FakeKeychainBackend(key: "sk-saved")))
        await store.keychainReady()
        #expect(store.config.ai.apiKey == "sk-saved")
    }

    @Test func i1KeychainReadFailureNeverDeletesKey() async throws {
        let file = try directory.file("config.json", contents: #"{ "ai": { "api_key": "" } }"#)
        let backend = FakeKeychainBackend(key: "sk-precious")
        backend.failReads(with: errSecInteractionNotAllowed)
        let store = ConfigStore(fileURL: file, keychain: KeychainStore(backend: backend))
        await store.keychainReady()
        #expect(store.config.ai.apiKey == "")
        // 读取失败后随便改一个设置
        #expect(store.update { $0.sounds = false })
        #expect(backend.deleteCount == 0)
        #expect(backend.key == "sk-precious")
    }

    @Test func i1ClearingAKnownKeyDeletesIt() async throws {
        let file = try directory.file("config.json", contents: #"{ "ai": { "api_key": "" } }"#)
        let backend = FakeKeychainBackend(key: "sk-old")
        let store = ConfigStore(fileURL: file, keychain: KeychainStore(backend: backend))
        await store.keychainReady()
        #expect(store.update { $0.ai.apiKey = "" })
        #expect(backend.key == nil)
    }
}
