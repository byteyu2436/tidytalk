import Foundation
import Testing
@testable import TidytalkApp

/// 说话记录：保存时写进磁盘并按天数清理，不保存时只在内存里。
@MainActor
@Suite struct DictationStoreTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Tidytalk-dictations-\(UUID().uuidString)")
    }

    private func entry(_ text: String, daysAgo: Double = 0) -> HistoryEntry {
        HistoryEntry(date: Date().addingTimeInterval(-daysAgo * 86_400), transcript: text, output: text)
    }

    @Test func savedEntriesComeBackAfterRestart() throws {
        let dir = root()
        let store = DictationStore(root: dir, saving: true, retentionDays: 30)
        store.add(entry("第一句", daysAgo: 1))
        store.add(entry("第二句"))
        let reopened = DictationStore(root: dir, saving: true, retentionDays: 30)
        #expect(reopened.entries.map(\.output) == ["第二句", "第一句"])
        #expect(reopened.entries.first?.id == store.entries.first?.id)
        // 只有当前用户能读写
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "dictations.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func entriesOlderThanTheRetentionAreDeleted() {
        let dir = root()
        let store = DictationStore(root: dir, saving: true, retentionDays: 7)
        store.add(entry("旧的", daysAgo: 10))
        store.add(entry("新的", daysAgo: 1))
        #expect(store.entries.map(\.output) == ["新的"])
        store.configure(saving: true, retentionDays: 0)
        store.add(entry("很旧的", daysAgo: 400))
        #expect(store.entries.count == 2)
    }

    @Test func memoryOnlyKeepsTheLatestTwentyAndWritesNothing() {
        let dir = root()
        let store = DictationStore(root: dir, saving: false, retentionDays: 30)
        for index in 0..<25 { store.add(entry("第 \(index) 句")) }
        #expect(store.entries.count == DictationStore.memoryLimit)
        #expect(store.entries.first?.output == "第 24 句")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func turningSavingOffDeletesTheFileButKeepsThisSession() {
        let dir = root()
        let store = DictationStore(root: dir, saving: true, retentionDays: 30)
        store.add(entry("这一句"))
        let file = dir.appending(path: "dictations.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.configure(saving: false, retentionDays: 30)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.entries.map(\.output) == ["这一句"])
        store.configure(saving: true, retentionDays: 30)
        #expect(DictationStore(root: dir, saving: true, retentionDays: 30).entries.count == 1)
    }
}
