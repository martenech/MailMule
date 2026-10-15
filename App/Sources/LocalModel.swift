import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// A small language model running on this Mac with MLX: loaded when needed, freed after a few idle minutes.
/// Mail never leaves the Mac.
@MainActor
@Observable
final class LocalModel {
    enum Choice: String, CaseIterable, Codable, Identifiable {
        case qwen35_4b, qwen3_4b, qwen35_2b

        var id: String { rawValue }

        var title: String {
            switch self {
            case .qwen35_4b: "Qwen3.5 4B – odporúčaný"
            case .qwen3_4b: "Qwen3 4B"
            case .qwen35_2b: "Qwen3.5 2B – najmenší, rýchlejší"
            }
        }

        /// Download size in GB, for the settings and the download prompt.
        var size: Double {
            switch self {
            case .qwen35_4b: 3.1
            case .qwen3_4b: 2.3
            case .qwen35_2b: 1.8
            }
        }

        var configuration: ModelConfiguration {
            switch self {
            case .qwen35_4b: ModelConfiguration(id: "mlx-community/Qwen3.5-4B-4bit", extraEOSTokens: ["<|im_end|>"])
            case .qwen3_4b: LLMRegistry.qwen3_4b_4bit
            case .qwen35_2b: LLMRegistry.qwen3_5_2b_4bit
            }
        }

        var repository: String {
            if case .id(let id, _) = configuration.id { return id }
            return rawValue
        }
    }

    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case generating
        case failed(String)
    }

    private(set) var state: State = .idle
    private var container: ModelContainer?
    private var loadedChoice: Choice?
    private var unloadTask: Task<Void, Never>?

    /// Models live with Mailmule's data, not in the shared Hugging Face cache, so Settings can remove them.
    static let cacheDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Mailmule/Models", directoryHint: .isDirectory)
    }()

    private static func folder(of choice: Choice) -> URL {
        cacheDirectory.appending(path: "models--" + choice.repository.replacingOccurrences(of: "/", with: "--"))
    }

    func isDownloaded(_ choice: Choice) -> Bool {
        let snapshots = Self.folder(of: choice).appending(path: "snapshots")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return !items.isEmpty
    }

    func downloadedSize(_ choice: Choice) -> Int64 {
        StorageUsage.size(of: Self.folder(of: choice))
    }

    func delete(_ choice: Choice) {
        if loadedChoice == choice { unload() }
        try? FileManager.default.removeItem(at: Self.folder(of: choice))
    }

    /// Downloads (first time) and loads the model; later calls reuse it until it is freed.
    func prepare(_ choice: Choice) async throws -> ModelContainer {
        unloadTask?.cancel()
        if let container, loadedChoice == choice { return container }
        unload()
        state = isDownloaded(choice) ? .loading : .downloading(0)
        do {
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            let hub = HubClient(cache: HubCache(cacheDirectory: Self.cacheDirectory))
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hub),
                using: #huggingFaceTokenizerLoader(),
                configuration: choice.configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = fraction >= 1 ? .loading : .downloading(fraction)
                }
            }
            container = loaded
            loadedChoice = choice
            state = .ready
            return loaded
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Generates a reply to `prompt` under `instructions`; `onText` receives the text so far as it streams.
    func generate(_ choice: Choice, instructions: String, prompt: String, maxTokens: Int = 700,
                  onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let model = try await prepare(choice)
        state = .generating
        defer {
            state = .ready
            scheduleUnload()
        }
        // Small Qwen models answer better and much faster without their "thinking" pass.
        let session = ChatSession(model, instructions: instructions,
                                  generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.15, topP: 0.9),
                                  additionalContext: ["enable_thinking": false])
        var text = ""
        for try await chunk in session.streamResponse(to: prompt) {
            text += chunk
            onText(Self.clean(text))
        }
        return Self.clean(text)
    }

    /// Leftover reasoning tags, should a model emit them anyway.
    static func clean(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frees the model's memory after a few idle minutes.
    private func scheduleUnload(after minutes: Double = 5) {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    func unload() {
        unloadTask?.cancel()
        container = nil
        loadedChoice = nil
        Memory.clearCache()
        if case .failed = state { return }
        state = .idle
    }
}
