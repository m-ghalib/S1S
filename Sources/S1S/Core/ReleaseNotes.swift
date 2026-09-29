import Foundation

/// Release notes bundled from `Resources/CHANGELOG.md`, and the rule for when the
/// app announces them after an update.
enum ReleaseNotes {
    struct Entry: Equatable {
        let version: String
        let items: [String]
    }

    /// The running app's version and build, from Info.plist.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Every entry in the bundled changelog, newest first.
    static let bundled: [Entry] = {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "CHANGELOG", withExtension: "md"),
            Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return parse(text) }
        }
        return []
    }()

    /// Splits the changelog into "## <version>" sections of "- " bullets. Other
    /// lines (title, comments, blank lines) are ignored; a bullet's wrapped
    /// continuation lines join the bullet.
    static func parse(_ markdown: String) -> [Entry] {
        var entries: [Entry] = []
        var version: String?
        var items: [String] = []
        var inComment = false

        func flush() {
            if let version { entries.append(Entry(version: version, items: items)) }
            items = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                inComment = !line.contains("-->")
                continue
            }
            if line.hasPrefix("## ") {
                flush()
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                version = title.split(separator: " ").first.map(String.init)
            } else if version != nil, line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
            } else if version != nil, !line.isEmpty, !line.hasPrefix("#"), let last = items.popLast() {
                items.append(last + " " + line)
            }
        }
        flush()
        return entries
    }

    /// Compares dotted versions numerically; a missing component counts as 0, so
    /// "0.1.4" < "0.1.4.1" < "0.1.5".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Entries at or below `version`, newest first. The first one is what the
    /// What's New page leads with, so a build without its own entry shows the
    /// latest notes it includes.
    static func entries(upTo version: String, in all: [Entry]) -> [Entry] {
        all.filter { compare($0.version, version) != .orderedDescending }
            .sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    /// Whether launch should open What's New. Only a set-up user who moved to a
    /// newer version with its own notes sees it. A user with no recorded version
    /// but a finished setup came from a build before this check, so they count as
    /// updated; a fresh install goes through onboarding instead.
    static func shouldAnnounce(current: String, lastSeen: String?, isSetUp: Bool, hasNotes: Bool) -> Bool {
        guard isSetUp, hasNotes, !current.isEmpty else { return false }
        guard let lastSeen else { return true }
        return compare(current, lastSeen) == .orderedDescending
    }
}
