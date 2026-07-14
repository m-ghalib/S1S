import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Loads and holds the active MLX model, and downloads/swaps to a different one when
/// requested. Downloading is async and reports real byte-based progress.
///
/// Design principle: the **currently active, working model is never torn down** while
/// a new one downloads. `container`/`readyModelId` only change once the new model has
/// *successfully* finished loading — so trying (or failing to download) a different
/// model never leaves the user with broken autocomplete.
@MainActor
final class ModelProvider: ObservableObject {
    static let shared = ModelProvider()

    enum State: Equatable {
        case idle
        /// Downloading/loading `modelId`; the previously-ready model (if any) keeps
        /// serving suggestions in the meantime.
        case downloading(modelId: String, progress: Double)
        /// The file(s) are fully on disk and MLX is parsing/dequantizing the weights
        /// into memory — no more network I/O happens in this phase, so it shows no
        /// byte-based progress, just a spinner. Can legitimately take a while for
        /// multi-billion-parameter models.
        case finalizing(modelId: String)
        case ready(modelId: String)
        case failed(modelId: String, message: String)
    }

    @Published private(set) var state: State = .idle
    /// Called once a model finishes loading successfully (used to persist the choice).
    var onReady: ((String) -> Void)?

    /// The loaded container, available once a model is ready.
    private(set) var container: ModelContainer?
    private(set) var readyModelId: String?

    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private let maxAttempts = 3
    /// Grace period for small/multi-file repos, where the downloader writes each file
    /// to disk as it completes — real stalls show up as disk-growth silence quickly.
    private let stallTimeout: TimeInterval = 25
    /// Grace period used instead of `stallTimeout` once the remote repo is large. The
    /// underlying downloader (`swift-huggingface`'s `HTTPClient`) buffers a file's
    /// *entire* body in memory via `URLSession.data(for:)` before writing any of it to
    /// disk — so a multi-GB single-shard file (e.g. Gemma's `model.safetensors`) shows
    /// zero disk growth for the whole transfer even while downloading perfectly well.
    /// A short disk-growth watchdog would false-positive and cancel/retry forever.
    private let largeRepoStallTimeout: TimeInterval = 600
    private let largeRepoThreshold: Int64 = 100_000_000
    /// Once every byte is on disk, MLX moves on to parsing/dequantizing the weights —
    /// pure compute, no network, so disk-growth silence there is *expected*, not a
    /// stall. This is just a generous sanity ceiling against a genuine hang (e.g. a
    /// corrupt file), not a "no progress" watchdog.
    private let finalizeTimeout: TimeInterval = 900

    private init() {}

    var isReady: Bool { container != nil }

    /// Load (downloading if needed) the given model id, replacing the active model
    /// only on success. Retries transient failures with backoff, and aborts+retries
    /// a stalled transfer (no byte growth for `stallTimeout`).
    func load(modelId: String) {
        loadTask?.cancel()
        progressTask?.cancel()
        state = .downloading(modelId: modelId, progress: 0)

        // Byte-based progress: poll actual bytes on disk against the HF API's real
        // file sizes, since the downloader's own Progress is (inaccurately) weighted
        // by file count.
        let remoteTotalTask = Task { await ModelStorage.remoteTotalSize(modelId) }

        progressTask = Task { [weak self] in
            guard let self else { return }
            let total = await remoteTotalTask.value
            while !Task.isCancelled {
                if case .downloading = self.state, let total, total > 0 {
                    let downloaded = ModelStorage.size(modelId)
                    if downloaded >= total {
                        self.state = .finalizing(modelId: modelId)
                    } else {
                        let frac = min(0.999, Double(downloaded) / Double(total))
                        self.state = .downloading(modelId: modelId, progress: frac)
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            let remoteTotal = await remoteTotalTask.value
            var lastMessage = "Unknown error"
            for attempt in 1...self.maxAttempts {
                if Task.isCancelled { return }
                do {
                    let container = try await self.attemptLoad(modelId: modelId, remoteTotal: remoteTotal)
                    if Task.isCancelled { return }
                    self.progressTask?.cancel()
                    self.container = container
                    self.readyModelId = modelId
                    self.state = .ready(modelId: modelId)
                    Log.shared.info("model ready: \(modelId)")
                    let isBase = ModelCatalog.all.first(where: { $0.id == modelId })?.isBase ?? true
                    if isBase {
                        Log.shared.info("model instructions: none (base model, raw continuation — no chat template/system prompt)")
                    } else {
                        Log.shared.info("model instructions (chat-template system message):\n---\n\(CompletionInstructions.system)\n---")
                    }
                    self.onReady?(modelId)
                    return
                } catch is CancellationError {
                    return
                } catch let error as StallError {
                    lastMessage = error.message
                    Log.shared.info("model load attempt \(attempt)/\(self.maxAttempts) stalled for \(modelId): \(error.message)")
                } catch {
                    lastMessage = error.localizedDescription
                    Log.shared.info("model load attempt \(attempt)/\(self.maxAttempts) failed for \(modelId): \(error.localizedDescription)")
                }
                if attempt < self.maxAttempts {
                    let backoff = pow(2.0, Double(attempt - 1))   // 1s, 2s, 4s…
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
            self.progressTask?.cancel()
            self.state = .failed(modelId: modelId, message: lastMessage)
            Log.shared.info("model load failed after \(self.maxAttempts) attempts: \(modelId) — \(lastMessage)")

            // Safety net: if NO model has ever loaded this session (e.g. the
            // configured model is stuck/broken from a previous failed download) and
            // this wasn't already the hardware-recommended fallback, try that instead
            // so the user isn't left with zero working autocomplete.
            let recommended = HardwareInfo.recommendedModelId
            if self.readyModelId == nil, modelId != recommended {
                Log.shared.info("falling back to recommended model: \(recommended)")
                self.load(modelId: recommended)
            }
        }
    }

    /// Retry after a failure.
    func retry(modelId: String) { load(modelId: modelId) }

    /// Cancel an in-flight download; falls back to whatever was last ready (or idle).
    func cancelDownload() {
        loadTask?.cancel()
        progressTask?.cancel()
        state = readyModelId.map { .ready(modelId: $0) } ?? .idle
    }

    private struct StallError: Error { let message: String }

    /// One load attempt, raced against a stall watchdog that cancels it if the byte
    /// count on disk hasn't grown for a grace period (the underlying downloader has no
    /// such timeout of its own — a hung connection would otherwise wait forever).
    ///
    /// The grace period scales with `remoteTotal`: large single-shard repos are
    /// downloaded via an API that buffers the entire file body in memory before
    /// writing anything to disk, so disk size can legitimately sit still for minutes
    /// during a perfectly healthy transfer.
    private func attemptLoad(modelId: String, remoteTotal: Int64?) async throws -> ModelContainer {
        let downloadTimeout = (remoteTotal ?? 0) > largeRepoThreshold ? largeRepoStallTimeout : stallTimeout
        Log.shared.info("attemptLoad: starting loadModelContainer for \(modelId) (cached bytes on disk: \(ModelStorage.size(modelId)), remote total: \(remoteTotal.map(String.init) ?? "unknown"))")
        let progressLog = ProgressLogger(modelId: modelId)
        let attempt = Task {
            let configuration = ModelConfiguration(id: modelId)
            return try await #huggingFaceLoadModelContainer(configuration: configuration) { progress in
                progressLog.log(progress)
            }
        }
        let watchdog = Task<Bool, Never> {
            var lastBytes = ModelStorage.size(modelId)
            var idleSeconds: TimeInterval = 0
            var finalizeSeconds: TimeInterval = 0
            var wasFinalizing = false
            var heartbeatSeconds: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                let now = ModelStorage.size(modelId)
                let fullyDownloaded = (remoteTotal ?? 0) > 0 && now >= remoteTotal!
                heartbeatSeconds += 3
                if heartbeatSeconds >= 30 {
                    heartbeatSeconds = 0
                    Log.shared.info("attemptLoad heartbeat: \(modelId) phase=\(fullyDownloaded ? "finalizing" : "downloading") diskBytes=\(now) idleSec=\(Int(idleSeconds)) finalizeSec=\(Int(finalizeSeconds))")
                }
                if fullyDownloaded {
                    if !wasFinalizing {
                        wasFinalizing = true
                        Log.shared.info("attemptLoad: \(modelId) fully on disk (\(now) bytes) — entering finalize/load phase")
                    }
                    // No more network I/O in this phase (MLX is parsing/dequantizing
                    // the weights) — disk silence here is expected, not a stall. Only
                    // guard against a genuine hang with a much longer ceiling.
                    finalizeSeconds += 3
                    if finalizeSeconds >= self.finalizeTimeout {
                        Log.shared.info("attemptLoad: \(modelId) finalize phase exceeded \(Int(self.finalizeTimeout))s — cancelling")
                        attempt.cancel()
                        return true
                    }
                    continue
                }
                if now > lastBytes { idleSeconds = 0; lastBytes = now } else { idleSeconds += 3 }
                if idleSeconds >= downloadTimeout {
                    Log.shared.info("attemptLoad: \(modelId) download phase exceeded \(Int(downloadTimeout))s with no disk growth — cancelling")
                    attempt.cancel()
                    return true
                }
            }
            return false
        }
        do {
            let result = try await attempt.value
            watchdog.cancel()
            Log.shared.info("attemptLoad: \(modelId) loadModelContainer returned successfully")
            return result
        } catch {
            Log.shared.info("attemptLoad: \(modelId) loadModelContainer threw: \(error)")
            // Cancel before awaiting — otherwise, when `attempt` throws quickly (e.g. an
            // unsupported model type), this would block for the watchdog's full grace
            // period (up to `finalizeTimeout`) waiting for a stall that will never
            // happen, since nothing is telling its loop to stop.
            watchdog.cancel()
            if await watchdog.value {
                throw StallError(message: "Model load stalled")
            }
            throw error
        }
    }
}

/// Logs `loadModelContainer`'s per-file download `Progress` callbacks, throttled to
/// once per whole-percentage change so a stuck attempt's exact position (which file,
/// how far into it) is visible in the log instead of being a silent black box.
private final class ProgressLogger: @unchecked Sendable {
    private let modelId: String
    private let lock = NSLock()
    private var lastLoggedPercent = -1

    init(modelId: String) { self.modelId = modelId }

    func log(_ progress: Progress) {
        let percent = Int(progress.fractionCompleted * 100)
        lock.lock()
        let shouldLog = percent != lastLoggedPercent
        if shouldLog { lastLoggedPercent = percent }
        lock.unlock()
        guard shouldLog else { return }
        Log.shared.info("loadModelContainer progress: \(modelId) \(progress.completedUnitCount)/\(progress.totalUnitCount) files (\(percent)%)")
    }
}
