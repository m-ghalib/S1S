import Foundation

/// Lightweight file logger for diagnosing behavior in specific apps without a
/// debugger. Writes to ~/Library/Logs/S1S/s1s.log. Verbose entries are
/// gated by `verbose` so normal runs stay quiet.
final class Log: @unchecked Sendable {
    static let shared = Log()

    var verbose = false

    private let url: URL
    private let queue = DispatchQueue(label: "app.s1s.log")
    private let formatter: DateFormatter

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/S1S", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("s1s.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    static var fileURL: URL { shared.url }

    /// Always-logged line (lifecycle, errors).
    func info(_ message: @autoclosure () -> String) { write(message()) }

    /// Only logged when verbose logging is enabled.
    func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write(message())
    }

    /// Past this size the log moves to `s1s.log.1` (replacing an older copy)
    /// and a new file starts, so verbose logging can't grow it without bound.
    private static let maxBytes: UInt64 = 5_000_000

    private func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                if handle.seekToEndOfFile() <= Self.maxBytes {
                    handle.write(data)
                    try? handle.close()
                    return
                }
                try? handle.close()
                let rotated = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            try? data.write(to: url)
        }
    }
}
