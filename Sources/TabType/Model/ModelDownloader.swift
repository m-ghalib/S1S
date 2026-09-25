import Foundation

/// A resumable, streaming downloader for MLX model repositories.
///
/// Why this exists: `swift-huggingface`'s snapshot download hands each file to
/// `URLSession.download(for:)`, which streams into a `CFNetworkDownload_*.tmp` in the
/// process temp directory and only moves the finished file into its cache. A cancelled
/// or dropped transfer therefore loses EVERY byte, and the retry restarts from zero —
/// so on a connection that can't pull a multi-GB model in one unbroken run, the model
/// can never finish downloading at all.
///
/// This downloader instead appends straight into `<file>.partial` inside our own model
/// directory and resumes with an HTTP `Range` request, so progress always survives a
/// cancel, a dropped connection, or app relaunch. It also reports exact byte progress,
/// which the snapshot API stops doing once a large blob starts transferring.
enum ModelDownloader {

    struct RemoteFile: Sendable {
        let name: String
        let size: Int64
    }

    enum Failure: LocalizedError {
        case listingFailed(String)
        case httpError(String, Int)
        /// Transfer ended before the whole file arrived. The `.partial` file is
        /// deliberately KEPT so the next attempt resumes instead of restarting.
        case incomplete(String, expected: Int64, got: Int64)
        case corrupt(String, expected: Int64, got: Int64)

        var errorDescription: String? {
            switch self {
            case .listingFailed(let id):
                return "Couldn't read the file list for \(id) from Hugging Face."
            case .httpError(let name, let code):
                return "Download of \(name) failed with HTTP \(code)."
            case .incomplete(let name, let expected, let got):
                return "\(name) stopped early at \(got) of \(expected) bytes — will resume."
            case .corrupt(let name, let expected, let got):
                return "\(name) downloaded corrupt (\(got) bytes, expected \(expected))."
            }
        }
    }

    /// Whether the snapshot downloader should be tried instead. Only structural
    /// problems qualify — a dropped connection must retry the RESUMABLE path, or we
    /// throw away the partial file we just worked to keep.
    static func shouldFallBack(to error: Error) -> Bool {
        if case Failure.listingFailed = error { return true }
        if case Failure.httpError = error { return true }
        return false
    }

    /// The files MLX actually loads — mirrors mlx-swift-lm's `modelDownloadPatterns`
    /// (`*.safetensors` + `*.json` + `*.jinja`). Top-level only: repos often carry
    /// whole extra formats (ONNX, GGUF) in subdirectories that MLX never reads.
    private static let neededExtensions = [".safetensors", ".json", ".jinja"]

    static func neededFiles(modelId: String) async throws -> [RemoteFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelId)?blobs=true") else {
            throw Failure.listingFailed(modelId)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.httpError(modelId, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]]
        else { throw Failure.listingFailed(modelId) }

        let files: [RemoteFile] = siblings.compactMap { entry in
            guard let name = entry["rfilename"] as? String,
                  !name.contains("/"),
                  neededExtensions.contains(where: { name.hasSuffix($0) })
            else { return nil }
            return RemoteFile(name: name, size: (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
        guard !files.isEmpty else { throw Failure.listingFailed(modelId) }
        return files
    }

    /// Offline-safe check that a directory holds a usable model: weights, a config,
    /// a tokenizer, and no unfinished `.partial` files. Used when the Hub can't be
    /// reached, so an already-downloaded model still loads without network.
    static func looksComplete(directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        guard !names.contains(where: { $0.hasSuffix(".partial") }) else { return false }
        return names.contains(where: { $0.hasSuffix(".safetensors") })
            && names.contains("config.json")
            && names.contains(where: { $0.hasPrefix("tokenizer") })
    }

    /// Whether `directory` already holds every needed file at its full size.
    static func isComplete(modelId: String, directory: URL, files: [RemoteFile]) -> Bool {
        files.allSatisfy { file in
            guard let size = fileSize(directory.appendingPathComponent(file.name)) else { return false }
            return file.size == 0 || size == file.size
        }
    }

    /// Download every needed file into `directory`, resuming anything partial.
    /// `progress` receives (bytesComplete, bytesTotal).
    static func download(modelId: String, revision: String = "main",
                         into directory: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let files = try await neededFiles(modelId: modelId)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Bytes already secured by files finished in an earlier run.
        var completedBytes: Int64 = 0
        for file in files {
            if let size = fileSize(directory.appendingPathComponent(file.name)),
               file.size == 0 || size == file.size {
                completedBytes += size
            }
        }
        progress(completedBytes, total)

        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.name)
            if let size = fileSize(destination), file.size == 0 || size == file.size {
                continue    // already have it
            }
            let partial = directory.appendingPathComponent(file.name + ".partial")
            let base = completedBytes
            let resumed = fileSize(partial) ?? 0
            if resumed > 0 {
                Log.shared.info("download: resuming \(file.name) at \(resumed) bytes")
            }
            try await downloadOne(
                modelId: modelId, revision: revision, file: file, partial: partial,
                onBytes: { written in progress(base + written, total) })
            let got = try publish(file: file, partial: partial, destination: destination)
            completedBytes = base + got
            progress(completedBytes, total)
        }
        progress(total, total)
    }

    /// Verify a finished `.partial` against the listed size, then move it to its
    /// real name. Returns the byte count.
    static func publish(file: RemoteFile, partial: URL, destination: URL) throws -> Int64 {
        let got = fileSize(partial) ?? 0
        if file.size > 0, got < file.size {
            // KEEP the partial — this is the whole point of the resumable path:
            // the retry picks up from these bytes instead of starting over.
            throw Failure.incomplete(file.name, expected: file.size, got: got)
        }
        if file.size > 0, got > file.size {
            try? FileManager.default.removeItem(at: partial)   // unusable
            throw Failure.corrupt(file.name, expected: file.size, got: got)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return got
    }

    private static func downloadOne(modelId: String, revision: String, file: RemoteFile,
                                    partial: URL,
                                    onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        guard let url = URL(string:
            "https://huggingface.co/\(modelId)/resolve/\(revision)/\(file.name)") else {
            throw Failure.listingFailed(file.name)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        let resumeOffset = Int64((try? handle.seekToEnd()) ?? 0)

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let streamer = FileStreamer(name: file.name, handle: handle,
                                    resumeOffset: resumeOffset, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: streamer, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
            try? handle.close()
        }
        try await streamer.run(session: session, request: request)
    }

    /// Reads the size from disk every time. `URL.resourceValues` caches per URL, so
    /// the `.partial` URL sized at resume start kept reporting that stale size after
    /// the transfer finished — a false "stopped early" on a full-size file.
    static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

/// Appends an HTTP body straight to disk as it arrives, so partial progress is durable.
private final class FileStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let name: String
    private let handle: FileHandle
    private let resumeOffset: Int64
    private let onBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var written: Int64 = 0
    private var failure: Error?
    /// Server said the range is already satisfied — the file is complete.
    private var alreadyComplete = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?

    init(name: String, handle: FileHandle, resumeOffset: Int64,
         onBytes: @escaping @Sendable (Int64) -> Void) {
        self.name = name
        self.handle = handle
        self.resumeOffset = resumeOffset
        self.onBytes = onBytes
        self.written = resumeOffset
        super.init()
    }

    func run(session: URLSession, request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = cont
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock(); let task = self.task; lock.unlock()
            task?.cancel()      // the .partial file keeps every byte written so far
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success: cont.resume()
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = ModelDownloader.Failure.httpError(name, -1)
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            break                       // resuming — append
        case 200:
            if resumeOffset > 0 {
                // Range ignored: the body is the whole file, so start over cleanly.
                try? handle.truncate(atOffset: 0)
                lock.lock(); written = 0; lock.unlock()
            }
        case 416:
            alreadyComplete = true      // nothing left to fetch
            completionHandler(.cancel)
            return
        default:
            failure = ModelDownloader.Failure.httpError(name, http.statusCode)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            lock.lock()
            written += Int64(data.count)
            let total = written
            lock.unlock()
            onBytes(total)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.synchronize()
        if let failure {
            finish(.failure(failure))
        } else if alreadyComplete {
            finish(.success(()))
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else {
            finish(.success(()))
        }
    }
}
