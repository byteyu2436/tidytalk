import Foundation
import Security
import Testing
@testable import TidytalkApp

@Suite struct KeychainStoreTests {
    @Test func resultIsCachedAfterFirstRead() {
        let backend = FakeKeychainBackend(key: "sk-1")
        let store = KeychainStore(backend: backend)
        #expect(store.cachedAPIKey == .unknown)
        #expect(store.readAPIKey() == "sk-1")
        #expect(store.readAPIKey() == "sk-1")
        #expect(backend.copyCount == 1)
        #expect(store.hasStoredKey)
    }

    @Test func missingKeyIsCachedToo() {
        let backend = FakeKeychainBackend()
        let store = KeychainStore(backend: backend)
        #expect(store.readAPIKey() == nil)
        #expect(store.readAPIKey() == nil)
        #expect(backend.copyCount == 1)
        #expect(store.cachedAPIKey == .missing)
        #expect(!store.hasStoredKey)
    }

    @Test func failedReadIsNotCached() {
        let backend = FakeKeychainBackend(key: "sk-1")
        backend.failReads(with: errSecAuthFailed)
        let store = KeychainStore(backend: backend)
        #expect(store.readAPIKey() == nil)
        #expect(store.cachedAPIKey == .unknown)
        #expect(!store.hasStoredKey)
        // 用户之后点了允许
        backend.failReads(with: nil)
        #expect(store.readAPIKey() == "sk-1")
    }

    @Test func saveAndDeleteUpdateTheCache() {
        let backend = FakeKeychainBackend()
        let store = KeychainStore(backend: backend)
        #expect(store.saveAPIKey("sk-new"))
        #expect(store.cachedAPIKey == .key("sk-new"))
        #expect(backend.key == "sk-new")
        #expect(store.saveAPIKey("sk-newer"))
        #expect(backend.key == "sk-newer")
        store.deleteAPIKey()
        #expect(store.cachedAPIKey == .missing)
        #expect(backend.key == nil)
    }
}
