import XCTest
@testable import S1S

/// Guards the carry-over from the TabType identity: models are multi-GB, so the old
/// Application Support folder must move, never be skipped or overwrite a newer one.
final class LegacyMigrationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("s1s-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testMovesLegacyFolderWhenNewOneIsMissing() throws {
        let old = root.appendingPathComponent("TabType/models", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let new = root.appendingPathComponent("S1S", isDirectory: true)

        XCTAssertTrue(LegacyMigration.migrateFolder(
            from: root.appendingPathComponent("TabType"), to: new, fileManager: .default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("models").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("TabType").path))
    }

    func testKeepsExistingNewFolder() throws {
        let old = root.appendingPathComponent("TabType", isDirectory: true)
        let new = root.appendingPathComponent("S1S", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        XCTAssertFalse(LegacyMigration.migrateFolder(from: old, to: new, fileManager: .default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testNoLegacyFolderIsANoOp() {
        XCTAssertFalse(LegacyMigration.migrateFolder(
            from: root.appendingPathComponent("TabType"),
            to: root.appendingPathComponent("S1S"), fileManager: .default))
    }
}
