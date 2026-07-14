import Foundation
import CryptoKit
import Security

/// Local, encrypted store of typed/accepted text snippets, used only to build a
/// short "words you use often" hint for the personalize-word-choice slider. Off by
/// default. Nothing here ever leaves the Mac: the file on disk is AES-GCM encrypted
/// with a key held in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
/// mirroring the "encrypted and stored locally" guarantee Cotypist's own Personalization
/// pane advertises.
@MainActor
final class TypingHistoryStore: ObservableObject {
    static let shared = TypingHistoryStore()

    @Published private(set) var entryCount = 0

    private var entries: [String] = []
    private let maxEntries = 500
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("typing-history.enc")
        load()
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
        persist()
    }

    func deleteAll() {
        entries = []
        entryCount = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The most frequent words across stored history, most-frequent first — used to
    /// build a subtle "frequently used words" hint in the prompt (see
    /// `AppSettings.personaPreface`), scaled by the personalize-word-choice slider.
    func topWords(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for entry in entries {
            for word in entry.split(separator: " ") {
                let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard w.count > 2 else { continue }
                counts[w, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: - Encrypted persistence

    private func persist() {
        guard let key = Self.encryptionKey(),
              let data = try? JSONEncoder().encode(entries),
              let sealed = try? AES.GCM.seal(data, using: key).combined
        else { return }
        try? sealed.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let key = Self.encryptionKey(),
              let sealed = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        entries = decoded
        entryCount = entries.count
    }

    // MARK: - Keychain-held key

    private static let keychainAccount = "app.tabtype.typinghistory.key"

    private static func encryptionKey() -> SymmetricKey? {
        if let existing = readKeychainKey() { return existing }
        let newKey = SymmetricKey(size: .bits256)
        writeKeychainKey(newKey)
        return newKey
    }

    private static func readKeychainKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func writeKeychainKey(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
