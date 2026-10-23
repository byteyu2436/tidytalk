import Foundation
import TidytalkCore

/// 管理当前的识别器：选中的模型下载好后在后台加载，切换模型或修改词库（热词）后重新加载。
///
/// 说话输入、实时字幕、文件转写共用这一份识别器，同一个模型只在内存里留一份。
@MainActor
final class RecognizerStore {
    /// 识别器和它对应的模型、热词。
    private struct Key: Equatable {
        let model: SpeechModel
        let hotwords: [String]
    }

    private let model: AppModel
    /// 现在能不能先释放旧模型再加载新的：正在录音或处理时要继续用旧的，返回 false。
    var canReleaseCurrent: () -> Bool = { true }

    private(set) var recognizer: (any SpeechTranscribing)?
    private var loadedKey: Key?
    private var loadingKey: Key?
    private var loadingTask: Task<(any SpeechTranscribing)?, Never>?

    init(model: AppModel) {
        self.model = model
        for manager in model.modelManagers.values {
            manager.onReady = { [weak self] in self?.load() }
        }
        observeChoice()
    }

    private var currentKey: Key {
        let config = model.configStore.config
        let hotwords = config.speechModel.supportsHotwords ? Vocabulary.normalize(config.vocabulary) : []
        return Key(model: config.speechModel, hotwords: hotwords)
    }

    /// 已经加载好、而且就是现在选中的模型和热词。
    var current: (any SpeechTranscribing)? {
        loadedKey == currentKey ? recognizer : nil
    }

    /// 已经加载了同一个模型和热词时什么都不做。
    func load() {
        let key = currentKey
        if loadedKey == key {
            // 加载别的模型期间又切回了已经加载好的这个：作废那次加载
            loadingKey = nil
            loadingTask = nil
            return
        }
        guard model.models.isReady, loadingKey != key else { return }
        let manager = model.models
        let directory = manager.directory
        // 空闲时先释放旧模型再加载新的，免得两个约 1 GB 的模型同时留在内存里
        if canReleaseCurrent() {
            recognizer = nil
            loadedKey = nil
        }
        loadingKey = key
        let task = Task.detached(priority: .userInitiated) { () -> Result<any SpeechTranscribing, Error> in
            Result { try SpeechRecognizers.load(key.model, directory: directory, hotwords: key.hotwords) }
        }
        loadingTask = Task { () -> (any SpeechTranscribing)? in
            if case .success(let loaded) = await task.value { return loaded }
            return nil
        }
        Task {
            let result = await task.value
            // 加载期间又换了模型，这次的结果作废
            guard loadingKey == key else { return }
            loadingTask = nil
            loadingKey = nil
            switch result {
            case .success(let loaded):
                recognizer = loaded
                loadedKey = key
            case .failure(let error):
                // 文件大小对但加载失败，多半是文件损坏：标记出来让用户重新下载，不再每次说话都重试
                manager.loadFailed(error.localizedDescription)
            }
        }
    }

    /// 现在选中的识别器；还在加载时等它加载完，加载失败返回 nil。
    func ready() async -> (any SpeechTranscribing)? {
        if let current { return current }
        load()
        guard loadingKey == currentKey, let task = loadingTask else { return nil }
        return await task.value
    }

    /// 切换识别模型或修改词库（热词）后，提前在后台加载，下次说话时不用等。
    private func observeChoice() {
        withObservationTracking {
            _ = model.configStore.config.speechModel
            _ = model.configStore.config.vocabulary
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.load()
                self?.observeChoice()
            }
        }
    }
}
