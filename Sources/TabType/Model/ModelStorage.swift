import Foundation

/// Inspects and manages downloaded MLX models in the Hugging Face cache
/// (~/.cache/huggingface/hub/models--org--name).
enum ModelStorage {
    private static var hubDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    static func cacheDir(for modelId: String) -> URL {
        let safe = modelId.replacingOccurrences(of: "/", with: "--")
        return hubDir.appendingPathComponent("models--\(safe)", isDirectory: true)
    }

    static func isInstalled(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheDir(for: modelId).path)
    }

    static func size(_ modelId: String) -> Int64 {
        directorySize(cacheDir(for: modelId))
    }

    static func totalUsed() -> Int64 {
        directorySize(hubDir)
    }

    /// Delete a downloaded model's cache directory (user-initiated).
    static func delete(_ modelId: String) {
        try? FileManager.default.removeItem(at: cacheDir(for: modelId))
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            let vals = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
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
