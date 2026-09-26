import Foundation
import CryptoKit

/// Local, encrypted store of typed/accepted text snippets, used only to build a
/// short "words you use often" hint for the personalize-word-choice slider. Off by
/// default. Nothing here ever leaves the Mac: the file on disk is AES-GCM encrypted
/// with a 256-bit key kept in a 0600 file (complete file protection) alongside it —
/// a filesystem-permission approach that (unlike the Keychain) never prompts for
/// the login password across rebuilds or code-signature changes.
@MainActor
final class TypingHistoryStore: ObservableObject {
    static let shared = TypingHistoryStore()

    @Published private(set) var entryCount = 0
    /// Stored few-shot pairs (onboarding picks and real accepts).
    @Published private(set) var pairCount = 0

    /// One accepted completion, with the text that preceded it — used as a
    /// personal few-shot example so the model sees the user's own register.
    struct AcceptPair: Codable, Sendable, Equatable {
        /// Where a pair came from. Onboarding pairs are the user's completion picks
        /// from first-run setup; they are kept apart from real accepts so redo can
        /// replace them and real accepts can take their place in the prompt.
        enum Source: String, Codable, Sendable { case accepted, onboarding }

        var prefixTail: String
        var accepted: String
        var source: Source = .accepted

        init(prefixTail: String, accepted: String, source: Source = .accepted) {
            self.prefixTail = prefixTail
            self.accepted = accepted
            self.source = source
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prefixTail = try c.decode(String.self, forKey: .prefixTail)
            accepted = try c.decode(String.self, forKey: .accepted)
            // Snapshots written before `source` existed hold only real accepts.
            source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .accepted
        }
    }

    private struct Snapshot: Codable {
        var entries: [String]
        var accepts: [AcceptPair]
    }

    private var entries: [String] = []
    private var pairs = AcceptPairSet()
    private let maxEntries = 500
    private let fileURL: URL
    private let keyURL: URL

    /// Whether stored history exists on disk.
    nonisolated static var historyFileExists: Bool {
        FileManager.default.fileExists(atPath: defaultFileURL.path)
    }

    nonisolated private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabType", isDirectory: true)
            .appendingPathComponent("typing-history.enc")
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("typing-history.enc")
        keyURL = dir.appendingPathComponent("history.key")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            load()
        }
    }

    /// Record one short snippet (an accepted suggestion, or — when "store inputs
    /// without accepted completions" is on — a recent input string). Never the whole
    /// document; callers already pass short, bounded text.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(trimmed)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        entryCount = entries.count
        PhraseMemory.shared.ingest(trimmed)
        persist()
    }

    /// All stored snippets — feeds `PhraseMemory`.
    var allEntries: [String] { entries }

    /// Samples of the author's recent writing for prompt context — the Cotypist
    /// recipe: a mix of the MOST RECENT entries (current topics) and the LONGEST
    /// recent entries (richest voice signal), deduped, per-sample and total budget
    /// capped. Order: oldest→newest so the prompt reads chronologically.
    func contextSamples(budget: Int) -> [String] {
        guard !entries.isEmpty, budget > 40 else { return [] }
        let window = entries.suffix(100)
        let recent = Array(window.suffix(3))
        let longest = window.sorted { $0.count > $1.count }.prefix(2)
        var seen = Set<String>()
        var picked: [String] = []
        for entry in (Array(longest) + recent) where entry.count >= 12 {
            let sample = String(entry.prefix(160))
            guard seen.insert(sample.lowercased()).inserted else { continue }
            picked.append(sample)
        }
        // Restore chronological order, then trim to budget.
        picked.sort { a, b in
            (entries.lastIndex(of: a) ?? entries.lastIndex(where: { $0.hasPrefix(a) }) ?? 0)
                < (entries.lastIndex(of: b) ?? entries.lastIndex(where: { $0.hasPrefix(b) }) ?? 0)
        }
        var out: [String] = []
        var used = 0
        for s in picked {
            guard used + s.count <= budget else { continue }
            out.append(s)
            used += s.count
        }
        return out
    }

    /// Record an accepted completion with its preceding text, for personal
    /// few-shot examples.
    func recordAccept(prefixTail: String, accepted: String) {
        guard pairs.recordAccept(prefixTail: prefixTail, accepted: accepted) else { return }
        pairCount = pairs.all.count
        persist()
    }

    /// Replace the onboarding pairs with a new set, keeping real accepts. Called
    /// on onboarding completion and redo, whether or not collection is on:
    /// finishing the picks is consent to store them.
    func replaceOnboardingPairs(_ newPairs: [AcceptPair]) {
        pairs.replaceOnboarding(with: newPairs)
        pairCount = pairs.all.count
        persist()
    }

    /// Few-shot examples for the prompt at the given personalization level. Real
    /// accepts count only when `includeRealAccepts` (typing history collection).
    func fewShotExamples(level: Double, includeRealAccepts: Bool) -> [AcceptPair] {
        pairs.fewShotExamples(level: level, includeRealAccepts: includeRealAccepts)
    }

    func deleteAll() {
        entries = []
        pairs = AcceptPairSet()
        entryCount = 0
        pairCount = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Function/stop words carry no personal-style signal, and feeding one to the
    /// model as "a word this person uses often" actively steers a small model into
    /// echoing it. Filter them out of the frequency count entirely.
    nonisolated private static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "that", "this", "with", "have", "has",
        "had", "from", "what", "when", "where", "why", "who", "how", "are", "was",
        "were", "will", "would", "could", "should", "can", "not", "but", "they",
        "them", "then", "than", "there", "here", "just", "like", "about", "into",
        "over", "some", "all", "out", "get", "got", "its", "it's", "i'm", "don't",
        "very", "also", "been", "being", "our", "their",
    ]

    /// The most frequent words across stored history, most-frequent first — used to
    /// build a subtle "frequently used words" hint in the prompt (see
    /// `AppSettings.personaPreface`), scaled by the personalize-word-choice slider.
    /// Stopwords are excluded and a word must recur (count ≥ 3) to qualify, so a
    /// sparse history yields nothing rather than a misleading one-word "hint".
    func topWords(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for entry in entries {
            for word in entry.split(separator: " ") {
                let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard w.count > 3, !Self.stopwords.contains(w) else { continue }
                counts[w, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    // MARK: - Encrypted persistence

    private func persist() {
        guard let key = encryptionKey(),
              let data = try? JSONEncoder().encode(Snapshot(entries: entries, accepts: pairs.all)),
              let sealed = try? AES.GCM.seal(data, using: key).combined
        else { return }
        try? sealed.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let key = encryptionKey(),
              let sealed = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key)
        else { return }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            entries = snapshot.entries
            pairs = AcceptPairSet(snapshot.accepts)
        } else if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            entries = legacy   // pre-accepts schema
        }
        entryCount = entries.count
        pairCount = pairs.all.count
    }

    // MARK: - Encryption key (file-based)

    /// The AES key lives in a 0600 file next to the encrypted history, NOT the
    /// Keychain. Keychain access is gated by the app's code signature, so it
    /// prompted for the login password on every rebuild / signature change (and
    /// mid-typing when history was touched). A permission-locked key file keeps
    /// the history encrypted at rest without any signature dependency or prompts.
    private func encryptionKey() -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: keyURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        } catch {
            return nil
        }
        return key
    }
}

/// Real accepts and onboarding pairs, held apart. Pure value logic so the
/// onboarding rules run under `swift test` without the encrypted store.
struct AcceptPairSet: Equatable {
    typealias Pair = TypingHistoryStore.AcceptPair

    static let maxAccepts = 50

    private(set) var real: [Pair] = []
    private(set) var onboarding: [Pair] = []

    init() {}

    init(_ all: [Pair]) {
        real = all.filter { $0.source == .accepted }
        onboarding = all.filter { $0.source == .onboarding }
    }

    /// Stored order: onboarding pairs first, then real accepts oldest→newest.
    var all: [Pair] { onboarding + real }

    /// Append one real accept. Returns false when either side is empty.
    @discardableResult
    mutating func recordAccept(prefixTail: String, accepted: String) -> Bool {
        let p = prefixTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = accepted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !a.isEmpty else { return false }
        real.append(Pair(prefixTail: String(p.suffix(80)), accepted: String(a.prefix(80))))
        if real.count > Self.maxAccepts { real.removeFirst(real.count - Self.maxAccepts) }
        return true
    }

    mutating func replaceOnboarding(with pairs: [Pair]) {
        onboarding = pairs.map { Pair(prefixTail: $0.prefixTail, accepted: $0.accepted, source: .onboarding) }
    }

    /// How many few-shot pairs the prompt carries at a personalization level:
    /// none when off, 2 at the post-onboarding default of 0.25, one more per
    /// further quarter step, capped at 4.
    static func exampleLimit(level: Double) -> Int {
        guard level > 0 else { return 0 }
        return min(4, max(1, 2 + Int(((level - 0.25) * 4).rounded(.down))))
    }

    /// The newest real accepts fill the slots first; onboarding pairs fill what is
    /// left, so each real accept displaces one onboarding pair. Oldest→newest.
    func fewShotExamples(level: Double, includeRealAccepts: Bool) -> [Pair] {
        let limit = Self.exampleLimit(level: level)
        let realPicked = includeRealAccepts ? Array(real.suffix(limit)) : []
        return Array(onboarding.prefix(limit - realPicked.count)) + realPicked
    }
}
