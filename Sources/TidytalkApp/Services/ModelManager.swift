import CryptoKit
import Foundation
import Observation
import TidytalkCore

/// 管理一个语音识别模型的下载、校验和本地状态。
///
/// 下载支持断点续传（未完成的数据保存在 `*.part` 文件中），一个下载源失败时自动换下一个。
/// Apple 系统识别没有文件，由系统下载和管理。
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

    let speechModel: SpeechModel
    let spec: ModelSpec?
    private(set) var status: Status = .missing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onReady: (() -> Void)?
    /// 下载完成后执行一次，用于"选中还没下载的模型时，下载好再切换过去"。
    @ObservationIgnored var useWhenReady: (() -> Void)?
    /// 文件大小对但加载失败（多半是文件损坏），需要删掉重新下载。
    private(set) var needsRedownload = false

    init(model: SpeechModel = .senseVoice) {
        speechModel = model
        spec = model.spec
        if spec != nil {
            status = isInstalled ? .ready : .missing
        } else {
            refreshAppleStatus()
        }
    }

    /// Apple 系统识别的模型由系统管理，用户可能删掉或者换了系统语言：打开设置、使用前重新检查。
    func refreshAppleStatus() {
        guard spec == nil, !isBusy else { return }
        Task { [weak self] in
            let installed = await AppleSpeech.isInstalled()
            guard let self, !self.isBusy else { return }
            if installed {
                if self.status != .ready { self.status = .ready }
            } else if self.status == .ready {
                self.status = .missing
            }
        }
    }

    /// 模型加载失败：文件大小对但内容多半已损坏，标记出来让用户重新下载，不再反复加载。
    func loadFailed(_ reason: String) {
        status = .failed(String(localized: "模型加载失败，文件可能已损坏，请重新下载（\(reason)）"))
        needsRedownload = spec != nil
    }

    /// 需要下载的大小；Apple 系统识别由系统下载，为 nil。
    var totalSize: Int64? { spec?.totalSize }

    /// 下载过的文件可以删除，腾出空间；Apple 系统识别由系统管理。
    var canDelete: Bool { spec != nil && !isBusy && status != .missing }

    func delete() {
        guard spec != nil, task == nil else { return }
        try? FileManager.default.removeItem(at: directory)
        status = .missing
    }

    var isReady: Bool { status == .ready }
    var isBusy: Bool {
        switch status {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// 模型文件所在的目录；Apple 系统识别没有目录，返回一个不存在的路径。
    var directory: URL {
        spec.map(Self.directory(for:)) ?? URL.applicationSupportDirectory.appending(path: "Tidytalk/Models/apple")
    }

    nonisolated static func directory(for spec: ModelSpec) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Tidytalk/Models", directoryHint: .isDirectory)
            .appending(path: spec.directoryName, directoryHint: .isDirectory)
    }

    /// 启动时只核对文件大小，完整性在下载完成时已经用 SHA-256 校验过。
    private var isInstalled: Bool {
        guard let spec else { return false }
        return spec.files.allSatisfy { size(of: directory.appending(path: $0.name)) == $0.size }
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
        guard task == nil, spec != nil else { return }
        try? FileManager.default.removeItem(at: directory)
        status = .missing
        needsRedownload = false
        download()
    }

    private func runDownload() async {
        guard let spec else {
            await runAppleInstall()
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try checkFreeSpace(for: spec)
            var completedBytes: Int64 = 0

            for file in spec.files {
                let destination = directory.appending(path: file.name)
                if size(of: destination) == file.size {
                    completedBytes += file.size
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                // 有的文件放在子目录里（例如 tokenizer/vocab.json）
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let part = directory.appending(path: file.name + ".part")

                try await downloadFromAnySource(file, of: spec, to: part, completedBefore: completedBytes)
                try FileManager.default.moveItem(at: part, to: destination)
                completedBytes += file.size
            }

            status = .ready
            onReady?()
            useWhenReady?()
            useWhenReady = nil
        } catch is CancellationError {
            status = .failed(String(localized: "下载已暂停"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Apple 系统识别：请系统下载当前语言的识别模型。
    private func runAppleInstall() async {
        status = .downloading(fraction: 0, source: "Apple")
        do {
            try await AppleSpeech.install { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(fraction: fraction, source: "Apple")
                }
            }
            status = .ready
            onReady?()
            useWhenReady?()
            useWhenReady = nil
        } catch is CancellationError {
            status = .failed(String(localized: "下载已暂停"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func downloadFromAnySource(_ file: ModelSpec.File, of spec: ModelSpec, to part: URL,
                                       completedBefore: Int64) async throws {
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
                // 用户点了暂停：下载被取消时会正常结束，要在这里区分，否则会显示成"下载不完整"
                try Task.checkCancellation()
                guard size(of: part) == file.size else {
                    lastError = DownloadError.incomplete
                    continue
                }
                status = .verifying
                if try await Self.sha256(of: part) == file.sha256 { return }
                // 这个源的文件不对：删掉，换下一个源重新下载
                try? FileManager.default.removeItem(at: part)
                lastError = DownloadError.checksumMismatch
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 下载前确认磁盘空间够用（留 200 MB 余量），免得下到一半才失败。
    private func checkFreeSpace(for spec: ModelSpec) throws {
        let remaining = spec.files.reduce(Int64(0)) { sum, file in
            sum + max(0, file.size - size(of: directory.appending(path: file.name)) - size(of: directory.appending(path: file.name + ".part")))
        }
        guard remaining > 0,
              let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        else { return }
        if free < remaining + 200_000_000 { throw DownloadError.noSpace(remaining) }
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
    case noSpace(Int64)

    var errorDescription: String? {
        switch self {
        case .noSource: String(localized: "没有可用的下载源")
        case .incomplete: String(localized: "下载不完整，请重试")
        case .checksumMismatch: String(localized: "文件已损坏，请重新下载")
        case .http: String(localized: "下载失败，请检查网络后重试")
        case .noSpace(let bytes):
            String(localized: "磁盘空间不足，还需要 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
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
