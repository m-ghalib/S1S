import Foundation

/// One-time carry-over from the app's former TabType identity: settings stored under
/// the old bundle ID, and the Application Support folder (downloaded models, typing
/// history and its key). Runs before anything reads settings or those files.
enum LegacyMigration {
    static let legacyBundleID = "app.tabtype.TabType"
    static let legacySupportFolder = "TabType"
    static let supportFolder = "S1S"
    private static let doneKey = "migratedFromTabType"

    static func run(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: doneKey) else { return }
        migrateDefaults(into: defaults)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateFolder(from: support.appendingPathComponent(legacySupportFolder, isDirectory: true),
                      to: support.appendingPathComponent(supportFolder, isDirectory: true),
                      fileManager: fileManager)
        defaults.set(true, forKey: doneKey)
    }

    /// Copies every key from the legacy domain that the new domain doesn't already have.
    static func migrateDefaults(into defaults: UserDefaults) {
        guard let legacy = defaults.persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Moves the legacy folder into place unless the new one already exists.
    @discardableResult
    static func migrateFolder(from old: URL, to new: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else {
            return false
        }
        return (try? fileManager.moveItem(at: old, to: new)) != nil
    }
}
