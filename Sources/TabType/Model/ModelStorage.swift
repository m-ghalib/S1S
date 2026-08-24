import Foundation

/// Inspects and manages downloaded MLX models. Models live in one of two places:
/// TabType's own store (`~/Library/Application Support/TabType/models`, written by
/// `ModelDownloader`) or the legacy Hugging Face cache
/// (`~/.cache/huggingface/hub/models--org--name`) used by earlier versions and by
/// swift-huggingface's own snapshot downloader. Every query below covers both so a
/// model downloaded by either path counts as installed exactly once.
enum ModelStorage {
    private static var hubDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// TabType's own model store. Deliberately NOT under `~/Library/Caches`: macOS
    /// purges that directory under disk pressure, which silently deletes multi-GB
    /// weights out from under a working install (observed in the field).
    private static var localModelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabType/models", isDirectory: true)
    }

    static func cacheDir(for modelId: String) -> URL {
        let safe = modelId.replacingOccurrences(of: "/", with: "--")
        return hubDir.appendingPathComponent("models--\(safe)", isDirectory: true)
    }

    /// Where `ModelDownloader` stages and keeps this model's files.
    static func localDir(for modelId: String) -> URL {
        let safe = modelId.replacingOccurrences(of: "/", with: "--")
        return localModelsDir.appendingPathComponent(safe, isDirectory: true)
    }

    /// The directory to show the user (whichever actually holds the model).
    static func revealDir(for modelId: String) -> URL {
        let local = localDir(for: modelId)
        return FileManager.default.fileExists(atPath: local.path) ? local : cacheDir(for: modelId)
    }

    /// Whether the legacy Hugging Face cache holds every file MLX needs, checked by
    /// NAME inside a snapshot revision (`snapshots/<rev>/<file>` symlinks into
    /// `blobs/`). Byte totals can't answer this: the Hub API's total counts files MLX
    /// never downloads (README, .gitattributes), so a fully-cached model always looks
    /// a little "short" and would be re-downloaded needlessly.
    static func legacyHasFiles(_ modelId: String, names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        let snapshots = cacheDir(for: modelId).appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return false }
        return revisions.contains { revision in
            names.allSatisfy {
                // fileExists follows the symlink, so a dangling link counts as missing.
                FileManager.default.fileExists(atPath: revision.appendingPathComponent($0).path)
            }
        }
    }

    /// Bytes held in the legacy Hugging Face cache only — used to decide whether a
    /// model is already fully downloaded there and needs no new transfer.
    static func legacySize(_ modelId: String) -> Int64 {
        directorySize(cacheDir(for: modelId))
    }

    static func isInstalled(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheDir(for: modelId).path)
            || FileManager.default.fileExists(atPath: localDir(for: modelId).path)
    }

    static func size(_ modelId: String) -> Int64 {
        directorySize(cacheDir(for: modelId)) + directorySize(localDir(for: modelId))
    }

    /// Bytes staged by URLSession for downloads that started at/after `since`.
    ///
    /// `URLSession.download(for:)` streams a file into a `CFNetworkDownload_*.tmp`
    /// under the process temp directory and only moves it into the model cache once
    /// the transfer COMPLETES. swift-huggingface's own byte callbacks also go quiet
    /// for the duration of a large blob, so during the multi-GB part of a model
    /// download this staging file is the ONLY signal that anything is happening:
    /// the cache directory cannot grow, and no progress is reported. Counting it is
    /// what keeps the stall watchdog from cancelling a perfectly healthy transfer
    /// (and, because cancelling discards the staging file, retrying from zero
    /// forever).
    ///
    /// The `since` filter skips staging files left by other processes/older runs.
    static func inFlightBytes(since: Date) -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for url in entries where url.lastPathComponent.hasPrefix("CFNetworkDownload_") {
            guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate,
                  modified >= since
            else { continue }
            total += Int64(size)
        }
        return total
    }

    static func totalUsed() -> Int64 {
        directorySize(hubDir) + directorySize(localModelsDir)
    }

    /// Delete a downloaded model's cache directory (user-initiated).
    static func delete(_ modelId: String) {
        try? FileManager.default.removeItem(at: localDir(for: modelId))
        try? FileManager.default.removeItem(at: cacheDir(for: modelId))
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            let vals = try? f.resourceValues(forKeys: Set(keys))
            // The Hugging Face cache stores each file once under `blobs/` and links to
            // it from `snapshots/`; counting the links too reported >100% of a model's
            // real size, which made downloads look "complete" before they were.
            if vals?.isSymbolicLink == true { continue }
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
        }
        return total
    }

    /// The model's true total size in bytes, summed from the Hugging Face API's
    /// per-file `size` field. Used for accurate byte-based download progress — the
    /// underlying downloader's own `Progress` is weighted by *file count*, which is
    /// wildly inaccurate for repos where one file (e.g. the safetensors weights) is
    /// 99% of the bytes. Returns nil on any network/parse failure (fails open).
    static func remoteTotalSize(_ modelId: String) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelId)?blobs=true") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = json["siblings"] as? [[String: Any]] else { return nil }
            let total = siblings.reduce(Int64(0)) { sum, file in
                sum + Int64((file["size"] as? NSNumber)?.int64Value ?? 0)
            }
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }
}
