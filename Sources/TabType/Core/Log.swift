import Foundation

/// Lightweight file logger for diagnosing behavior in specific apps without a
/// debugger. Writes to ~/Library/Logs/TabType/tabtype.log. Verbose entries are
/// gated by `verbose` so normal runs stay quiet.
final class Log: @unchecked Sendable {
    static let shared = Log()

    var verbose = false

    private let url: URL
    private let queue = DispatchQueue(label: "app.tabtype.log")
    private let formatter: DateFormatter

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TabType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tabtype.log")
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

    private func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [url] in
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
