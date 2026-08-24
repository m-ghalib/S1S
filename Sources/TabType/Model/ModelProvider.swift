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
    /// Extra retries granted to attempts that actually transferred bytes before
    /// failing (see the retry loop) — enough to ride out a very flaky connection.
    private let maxResumedRetries = 20
    /// How long the transfer may report NO byte progress before it counts as stalled.
    /// This watches the downloader's own byte callbacks (see `DownloadTracker`), not
    /// disk growth: `URLSession.download(for:)` streams into a `CFNetworkDownload_*.tmp`
    /// in the process temp dir and only moves the finished file into the model cache,
    /// so a multi-GB blob shows ZERO cache growth for its entire (perfectly healthy)
    /// download. Watching disk size here used to cancel good downloads — and because a
    /// cancel discards the temp file, every retry restarted from zero, so anyone whose
    /// connection couldn't finish inside the old 600s window could never install a
    /// model at all.
    private let stallTimeout: TimeInterval = 45
    /// Grace period before the FIRST byte callback arrives (repo metadata, tree
    /// listing and connection setup all happen before any bytes flow).
    private let startupTimeout: TimeInterval = 120
    /// Once every byte is on disk, MLX moves on to parsing/dequantizing the weights —
    /// pure compute, no network, so disk-growth silence there is *expected*, not a
    /// stall. This is just a generous sanity ceiling against a genuine hang (e.g. a
    /// corrupt file), not a "no progress" watchdog.
    private let finalizeTimeout: TimeInterval = 900

    /// Live byte progress reported by the downloader itself — the single source of
    /// truth for both the progress UI and the stall watchdog.
    private let tracker = DownloadTracker()

    private init() {}

    var isReady: Bool { container != nil }

    /// Load (downloading if needed) the given model id, replacing the active model
    /// only on success. Retries transient failures with backoff, and aborts+retries
    /// a stalled transfer (no byte growth for `stallTimeout`).
    func load(modelId: String) {
        loadTask?.cancel()
        progressTask?.cancel()
        state = .downloading(modelId: modelId, progress: 0)

        tracker.reset()
        let remoteTotalTask = Task { await ModelStorage.remoteTotalSize(modelId) }
        let loadStarted = Date()

        progressTask = Task { [weak self] in
            guard let self else { return }
            let remoteTotal = await remoteTotalTask.value
            while !Task.isCancelled {
                if case .downloading = self.state {
                    let snap = self.tracker.snapshot()
                    let total = remoteTotal ?? (snap.total > 0 ? snap.total : 0)
                    // Same three signals as the watchdog: reported bytes, bytes already
                    // in the cache, and bytes staged by URLSession for the file
                    // currently in flight. Without the staging bytes the bar sits at
                    // 0% for the entire multi-GB download.
                    let done = max(snap.completed,
                                   ModelStorage.size(modelId)
                                       + ModelStorage.inFlightBytes(since: loadStarted))
                    if total > 0 {
                        if (snap.total > 0 && snap.completed >= snap.total)
                            || ModelStorage.size(modelId) >= total {
                            self.state = .finalizing(modelId: modelId)
                        } else {
                            self.state = .downloading(modelId: modelId,
                                                      progress: min(0.999, Double(done) / Double(total)))
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            let remoteTotal = await remoteTotalTask.value
            var lastMessage = "Unknown error"
            var attempt = 0
            var resumedRetries = 0
            while attempt < self.maxAttempts {
                attempt += 1
                if Task.isCancelled { return }
                let bytesBefore = ModelStorage.size(modelId)
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
                // A flaky connection drops repeatedly, but each resumable attempt
                // banks real progress — so an attempt that moved bytes doesn't count
                // against the retry budget (bounded, so a genuinely broken repo still
                // gives up). Without this a slow/unstable link could never finish a
                // multi-GB model.
                if ModelStorage.size(modelId) > bytesBefore, resumedRetries < self.maxResumedRetries {
                    resumedRetries += 1
                    attempt -= 1
                    Log.shared.info("model download made progress before failing — resuming (\(resumedRetries)/\(self.maxResumedRetries))")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
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
        Log.shared.info("attemptLoad: starting loadModelContainer for \(modelId) (cached bytes on disk: \(ModelStorage.size(modelId)), remote total: \(remoteTotal.map(String.init) ?? "unknown"))")
        let progressLog = ProgressLogger(modelId: modelId)
        let tracker = self.tracker
        let attempt = Task {
            // Never re-download what the user already has. In order: TabType's own
            // store, then the legacy Hugging Face cache (earlier versions and
            // swift-huggingface's snapshot downloader), then an actual download.
            let directory = ModelStorage.localDir(for: modelId)
            let files = try? await ModelDownloader.neededFiles(modelId: modelId)
            let localComplete = files.map {
                ModelDownloader.isComplete(modelId: modelId, directory: directory, files: $0)
            } ?? ModelDownloader.looksComplete(directory: directory)
            let legacyComplete = files.map {
                ModelStorage.legacyHasFiles(modelId, names: $0.map(\.name))
            } ?? ModelStorage.isInstalled(modelId)
            var configuration = ModelConfiguration(id: modelId)
            if localComplete {
                Log.shared.info("attemptLoad: \(modelId) already complete in TabType's model store")
                configuration = ModelConfiguration(directory: directory)
            } else if legacyComplete {
                Log.shared.info("attemptLoad: \(modelId) already complete in the Hugging Face cache")
            } else {
                // Fetch with our own resumable downloader, which appends into
                // `<file>.partial` in TabType's model store: a cancel, a dropped
                // connection or a relaunch keeps every byte already transferred,
                // where the snapshot downloader would restart from zero.
                do {
                    try await ModelDownloader.download(modelId: modelId, into: directory) { done, total in
                        tracker.update(completed: done, total: total)
                    }
                    configuration = ModelConfiguration(directory: directory)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A dropped connection or short read must RETRY the resumable path
                    // (the `.partial` file is intact and the next attempt resumes from
                    // it) — falling back to the snapshot downloader here would discard
                    // that progress. Only structural problems (repo listing/HTTP shape)
                    // fall back, so we never regress on an unexpected repo layout.
                    guard ModelDownloader.shouldFallBack(to: error) else { throw error }
                    Log.shared.info("resumable download unavailable for \(modelId) (\(error.localizedDescription)) — falling back to snapshot download")
                }
            }
            // `progressHandler:` MUST be passed as a LABELED argument: the
            // `#huggingFaceLoadModelContainer` macro looks the handler up by label in
            // its argument list, so a trailing closure is silently expanded to
            // `{ _ in }` and every byte callback is discarded (that's why downloads
            // used to sit at "0%" with no progress lines in the log at all).
            return try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { progress in
                    tracker.update(completed: progress.completedUnitCount,
                                   total: progress.totalUnitCount)
                    progressLog.log(progress)
                })
        }
        let started = Date()
        let watchdog = Task<Bool, Never> { [stallTimeout, startupTimeout, finalizeTimeout] in
            var finalizeSeconds: TimeInterval = 0
            var wasFinalizing = false
            var heartbeatSeconds: TimeInterval = 0
            var lastCombined: Int64 = -1
            var idleSeconds: TimeInterval = 0
            var everGrew = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                let snap = tracker.snapshot()
                let diskBytes = ModelStorage.size(modelId)
                let inFlight = ModelStorage.inFlightBytes(since: started)
                // Any of the three signals moving means the transfer is alive. The
                // staging bytes are the only one that moves during a large blob.
                let combined = max(snap.completed, diskBytes + inFlight)
                // Finalizing = everything transferred; MLX is now parsing/dequantizing
                // (pure compute), so silence from here on is expected, not a stall.
                let fullyDownloaded = (snap.total > 0 && snap.completed >= snap.total)
                    || ((remoteTotal ?? 0) > 0 && diskBytes >= remoteTotal!)
                heartbeatSeconds += 3
                if heartbeatSeconds >= 30 {
                    heartbeatSeconds = 0
                    Log.shared.info("attemptLoad heartbeat: \(modelId) phase=\(fullyDownloaded ? "finalizing" : "downloading") transferred=\(combined)/\(remoteTotal ?? snap.total) (reported=\(snap.completed) disk=\(diskBytes) staging=\(inFlight)) idleSec=\(Int(idleSeconds)) finalizeSec=\(Int(finalizeSeconds))")
                }
                if fullyDownloaded {
                    if !wasFinalizing {
                        wasFinalizing = true
                        Log.shared.info("attemptLoad: \(modelId) transfer complete — entering finalize/load phase")
                    }
                    finalizeSeconds += 3
                    if finalizeSeconds >= finalizeTimeout {
                        Log.shared.info("attemptLoad: \(modelId) finalize phase exceeded \(Int(finalizeTimeout))s — cancelling")
                        attempt.cancel()
                        return true
                    }
                    continue
                }
                if combined > lastCombined {
                    lastCombined = combined
                    idleSeconds = 0
                    if combined > 0 { everGrew = true }
                } else {
                    idleSeconds += 3
                }
                // Before any bytes have moved at all (repo metadata, tree listing,
                // TLS handshake) allow a longer startup grace.
                let limit = everGrew ? stallTimeout : startupTimeout
                if idleSeconds >= limit {
                    Log.shared.info("attemptLoad: \(modelId) no bytes moved for \(Int(idleSeconds))s (limit \(Int(limit))s) — cancelling")
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

/// Byte progress reported by the downloader, plus when it last moved. Shared between
/// the progress UI and the stall watchdog so both see the same truth.
final class DownloadTracker: @unchecked Sendable {
    struct Snapshot {
        var completed: Int64
        var total: Int64
        var idleSeconds: TimeInterval
        /// Whether any byte callback has arrived yet for this attempt.
        var hasProgress: Bool
    }

    private let lock = NSLock()
    private var completed: Int64 = 0
    private var total: Int64 = 0
    private var lastChange: Date?

    func reset() {
        lock.lock()
        completed = 0; total = 0; lastChange = nil
        lock.unlock()
    }

    func update(completed newCompleted: Int64, total newTotal: Int64) {
        lock.lock()
        // Snapshot downloads report cumulative bytes; guard against a per-file
        // counter that restarts by keeping the high-water mark within an attempt.
        if newCompleted != completed || newTotal != total {
            completed = max(completed, newCompleted)
            total = max(total, newTotal)
            lastChange = Date()
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            completed: completed,
            total: total,
            idleSeconds: lastChange.map { Date().timeIntervalSince($0) } ?? 0,
            hasProgress: lastChange != nil)
    }
}

/// Logs `loadModelContainer`'s byte-level download `Progress` callbacks, throttled to
/// once per whole-percentage change so a stuck attempt's exact position is visible in
/// the log instead of being a silent black box.
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
        let mb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_048_576) }
        Log.shared.info("loadModelContainer progress: \(modelId) \(mb(progress.completedUnitCount))/\(mb(progress.totalUnitCount)) MB (\(percent)%)")
    }
}
