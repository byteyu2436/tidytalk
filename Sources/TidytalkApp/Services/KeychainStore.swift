import Foundation
import Security

/// 保存 AI 服务 API Key 的地方。正式运行时是钥匙串（`KeychainStore.shared`），测试时换成内存里的实现。
protocol APIKeyStore: AnyObject, Sendable {
    /// 缓存里的结果，不访问钥匙串，可以在主线程上调用。
    var cachedAPIKey: KeychainStore.Cached { get }
    /// 读取 Key；第一次可能要等用户在授权窗里点按钮，不要在主线程上调用。没有存或读取失败时为 nil。
    func readAPIKey() -> String?
    /// 确实读到过、存过一个 Key。只有这时清空 Key 才需要删除。
    var hasStoredKey: Bool { get }
    /// 保存成功返回 true；失败时调用方继续把 Key 写在配置文件里，不至于丢失。
    @discardableResult func saveAPIKey(_ key: String) -> Bool
    func deleteAPIKey()
}

/// 钥匙串的底层读写，测试时可以模拟"读取失败""用户拒绝授权"等情况。
protocol KeychainBackend: Sendable {
    func copy() -> (OSStatus, Data?)
    func update(_ data: Data) -> OSStatus
    func add(_ data: Data) -> OSStatus
    func delete() -> OSStatus
}

/// 把 AI 服务的 API Key 存在钥匙串里，不写进 `~/.tidytalk.json` 明文。
///
/// 读到的结果缓存在内存里：配置文件每次说话前都会重新读取，不能每次都去问钥匙串。
/// 读取失败（用户在授权窗里点了拒绝、钥匙串被锁）和"没有存 Key"分开处理，失败时不缓存、也绝不删除钥匙串里的 Key。
/// 钥匙串调用可能一直等到用户在授权窗里点按钮，所以调用期间不持有锁。
final class KeychainStore: APIKeyStore, @unchecked Sendable {
    static let shared = KeychainStore(backend: SecItemBackend())

    enum Cached: Equatable, Sendable { case unknown, missing, key(String) }

    private let backend: any KeychainBackend
    private let lock = NSLock()
    /// 只在持有 `lock` 时读写。
    private var cached = Cached.unknown

    init(backend: any KeychainBackend) {
        self.backend = backend
    }

    var cachedAPIKey: Cached { lock.withLock { cached } }

    func readAPIKey() -> String? {
        switch cachedAPIKey {
        case .key(let key): return key
        case .missing: return nil
        case .unknown: break
        }
        let found: Cached
        switch backend.copy() {
        case (errSecSuccess, let data?):
            guard let key = String(data: data, encoding: .utf8) else { return nil }
            found = .key(key)
        case (errSecItemNotFound, _):
            found = .missing
        default:
            // 读取失败：不缓存，下次再试
            return nil
        }
        // 读取期间可能已经保存或删除过，以那次的结果为准
        return lock.withLock {
            if cached == .unknown { cached = found }
            if case .key(let key) = cached { return key }
            return nil
        }
    }

    var hasStoredKey: Bool {
        if case .key = cachedAPIKey { true } else { false }
    }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        if cachedAPIKey == .key(key) { return true }
        let data = Data(key.utf8)
        var status = backend.update(data)
        if status == errSecItemNotFound { status = backend.add(data) }
        guard status == errSecSuccess else { return false }
        lock.withLock { cached = .key(key) }
        return true
    }

    func deleteAPIKey() {
        let status = backend.delete()
        if status == errSecSuccess || status == errSecItemNotFound { lock.withLock { cached = .missing } }
    }
}

/// 真正的钥匙串：登录钥匙串里的一个通用密码项目。
struct SecItemBackend: KeychainBackend {
    private static let service = "app.tidytalk.Tidytalk"
    private static let account = "ai.api_key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func copy() -> (OSStatus, Data?) {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ data: Data) -> OSStatus {
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func add(_ data: Data) -> OSStatus {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil)
    }

    func delete() -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
