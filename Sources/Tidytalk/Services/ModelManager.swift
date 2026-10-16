import CryptoKit
import Foundation
import Observation
import TidytalkCore

/// 管理语音识别模型的下载、校验和本地状态。
///
/// 下载支持断点续传（未完成的数据保存在 `*.part` 文件中），一个下载源失败时自动换下一个。
@MainActor
@Observable
final class ModelManager {
    enum Status: Equatable {
        case missing
        case downloading(fraction: Double, source: String)
        case verifying
        case ready
        case failed(String)
    }

    let spec: ModelSpec
    private(set) var status: Status = .missing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onReady: (() -> Void)?

    init(spec: ModelSpec = .senseVoice) {
        self.spec = spec
        status = isInstalled ? .ready : .missing
    }

    var isReady: Bool { status == .ready }
    var isBusy: Bool {
        switch status {
        case .downloading, .verifying: true
        default: false
        }
    }

    var directory: URL { Self.directory(for: spec) }

    nonisolated static func directory(for spec: ModelSpec) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Tidytalk/Models", directoryHint: .isDirectory)
            .appending(path: spec.directoryName, directoryHint: .isDirectory)
    }

    /// 启动时只核对文件大小，完整性在下载完成时已经用 SHA-256 校验过。
    private var isInstalled: Bool {
        spec.files.allSatisfy { size(of: directory.appending(path: $0.name)) == $0.size }
    }

    func download() {
        guard task == nil, status != .ready else { return }
        task = Task { [weak self] in
            await self?.runDownload()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 删除已下载的文件后重新下载。
    func redownload() {
        guard task == nil else { return }
        try? FileManager.default.removeItem(at: directory)
        status = .missing
        download()
    }

    private func runDownload() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var completedBytes: Int64 = 0

            for file in spec.files {
                let destination = directory.appending(path: file.name)
                if size(of: destination) == file.size {
                    completedBytes += file.size
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                let part = directory.appending(path: file.name + ".part")

                try await downloadFromAnySource(file, to: part, completedBefore: completedBytes)

                status = .verifying
                let digest = try await Self.sha256(of: part)
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: part)
                    throw DownloadError.checksumMismatch
                }
                try FileManager.default.moveItem(at: part, to: destination)
                completedBytes += file.size
            }

            status = .ready
            onReady?()
        } catch is CancellationError {
            status = .failed(String(localized: "下载已暂停"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func downloadFromAnySource(_ file: ModelSpec.File, to part: URL, completedBefore: Int64) async throws {
        var lastError: Error = DownloadError.noSource
        for source in spec.sources {
            try Task.checkCancellation()
            let total = Double(spec.totalSize)
            status = .downloading(fraction: Double(completedBefore + size(of: part)) / total, source: source.name)
            do {
                try await ResumableDownload.run(url: source.url(for: file), to: part) { [weak self] written in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(fraction: Double(completedBefore + written) / total,
                                                   source: source.name)
                    }
                }
                if size(of: part) == file.size { return }
                lastError = DownloadError.incomplete
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

enum DownloadError: LocalizedError {
    case noSource
    case incomplete
    case checksumMismatch
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noSource: String(localized: "没有可用的下载源")
        case .incomplete: String(localized: "下载不完整，请重试")
        case .checksumMismatch: String(localized: "文件已损坏，请重新下载")
        case .http: String(localized: "下载失败，请检查网络后重试")
        }
    }
}

/// 把 URL 的内容追加写入本地文件，已有部分通过 Range 请求续传。
private final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, existing: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.written = existing
        self.onProgress = onProgress
    }

    static func run(url: URL, to destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let existing = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?
            .int64Value ?? 0

        let download = ResumableDownload(destination: destination, existing: existing, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: download, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    download.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch code {
            case 206:
                handle = try FileHandle(forWritingTo: destination)
                try handle?.seekToEnd()
            case 200:
                // 服务器不支持续传，从头开始
                handle = try FileHandle(forWritingTo: destination)
                try handle?.truncate(atOffset: 0)
                written = 0
            case 416:
                // 本地已经是完整文件
                completionHandler(.cancel)
                return
            default:
                failure = DownloadError.http(code)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            // 进度最多每 0.1 秒回报一次
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 {
                lastReport = now
                onProgress(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result: Error?
        if let failure {
            result = failure
        } else if let error = error as? URLError, error.code == .cancelled {
            // 416 时主动取消属于正常结束；用户取消由外层 Task 检查
            result = nil
        } else {
            result = error
        }
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
