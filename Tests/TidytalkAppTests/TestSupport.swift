import Foundation
import Security
@testable import TidytalkApp

/// 内存里的"钥匙串"，可以模拟读取失败（用户在授权窗里点了拒绝、钥匙串被锁）。
final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var readStatus: OSStatus?
    private(set) var copies = 0
    private(set) var deletes = 0

    init(key: String? = nil) {
        stored = key.map { Data($0.utf8) }
    }

    /// 之后的读取都返回这个错误码（nil 恢复正常）。
    func failReads(with status: OSStatus?) { lock.withLock { readStatus = status } }

    var key: String? { lock.withLock { stored.map { String(decoding: $0, as: UTF8.self) } } }
    var copyCount: Int { lock.withLock { copies } }
    var deleteCount: Int { lock.withLock { deletes } }

    func copy() -> (OSStatus, Data?) {
        lock.withLock {
            copies += 1
            if let readStatus { return (readStatus, nil) }
            return stored.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func update(_ data: Data) -> OSStatus {
        lock.withLock {
            guard stored != nil else { return errSecItemNotFound }
            stored = data
            return errSecSuccess
        }
    }

    func add(_ data: Data) -> OSStatus {
        lock.withLock {
            stored = data
            return errSecSuccess
        }
    }

    func delete() -> OSStatus {
        lock.withLock {
            deletes += 1
            defer { stored = nil }
            return stored == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

/// 每个测试一个临时目录，结束时删掉。
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "TidytalkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String? = nil) throws -> URL {
        let file = url.appending(path: name)
        if let contents { try Data(contents.utf8).write(to: file) }
        return file
    }
}

extension URL {
    var text: String { (try? String(contentsOf: self, encoding: .utf8)) ?? "" }

    var posixPermissions: Int? {
        try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: self)) as? [String: Any]) ?? [:]
    }
}
