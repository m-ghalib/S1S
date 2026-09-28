import XCTest
@testable import TabType

final class ReleaseNotesTests: XCTestCase {

    private let sample = """
    # TabType release notes

    <!--
    ## 9.9.9
    - commented out
    -->

    ## 0.1.4.1

    - Hotfix for **Tab**.

    ## 0.1.4 (2026-09-28)

    - First item.
    - Second item that
      wraps onto a second line.

    ## 0.1.3
    - Old item.
    """

    func testParseSplitsVersionsAndBullets() {
        let entries = ReleaseNotes.parse(sample)
        XCTAssertEqual(entries.map(\.version), ["0.1.4.1", "0.1.4", "0.1.3"])
        XCTAssertEqual(entries[0].items, ["Hotfix for **Tab**."])
        XCTAssertEqual(entries[1].items, ["First item.", "Second item that wraps onto a second line."])
        XCTAssertEqual(entries[2].items, ["Old item."])
    }

    func testCompareTreatsMissingComponentsAsZero() {
        XCTAssertEqual(ReleaseNotes.compare("0.1.4", "0.1.4.1"), .orderedAscending)
        XCTAssertEqual(ReleaseNotes.compare("0.1.4.1", "0.1.5"), .orderedAscending)
        XCTAssertEqual(ReleaseNotes.compare("0.1.10", "0.1.9"), .orderedDescending)
        XCTAssertEqual(ReleaseNotes.compare("0.1.4", "0.1.4.0"), .orderedSame)
    }

    func testEntriesUpToVersionLeadWithTheBestMatch() {
        let all = ReleaseNotes.parse(sample)
        XCTAssertEqual(ReleaseNotes.entries(upTo: "0.1.4", in: all).map(\.version), ["0.1.4", "0.1.3"])
        // A dev build ahead of the changelog leads with the newest notes.
        XCTAssertEqual(ReleaseNotes.entries(upTo: "0.1.5", in: all).first?.version, "0.1.4.1")
        XCTAssertTrue(ReleaseNotes.entries(upTo: "0.1.2", in: all).isEmpty)
    }

    func testAnnounceOnlyAfterAnUpdateWithNotes() {
        // Newer version with notes.
        XCTAssertTrue(ReleaseNotes.shouldAnnounce(current: "0.1.5", lastSeen: "0.1.4", isSetUp: true, hasNotes: true))
        XCTAssertTrue(ReleaseNotes.shouldAnnounce(current: "0.1.4.1", lastSeen: "0.1.4", isSetUp: true, hasNotes: true))
        // Set-up user from a build that did not record a version.
        XCTAssertTrue(ReleaseNotes.shouldAnnounce(current: "0.1.5", lastSeen: nil, isSetUp: true, hasNotes: true))
        // Same version (rebuilds), downgrade, fresh install, or no notes.
        XCTAssertFalse(ReleaseNotes.shouldAnnounce(current: "0.1.5", lastSeen: "0.1.5", isSetUp: true, hasNotes: true))
        XCTAssertFalse(ReleaseNotes.shouldAnnounce(current: "0.1.4", lastSeen: "0.1.5", isSetUp: true, hasNotes: true))
        XCTAssertFalse(ReleaseNotes.shouldAnnounce(current: "0.1.5", lastSeen: nil, isSetUp: false, hasNotes: true))
        XCTAssertFalse(ReleaseNotes.shouldAnnounce(current: "0.1.5", lastSeen: "0.1.4", isSetUp: true, hasNotes: false))
    }

    func testBundledChangelogHasTheShippedVersion() {
        let entries = ReleaseNotes.bundled
        XCTAssertFalse(entries.isEmpty, "CHANGELOG.md is not bundled")
        XCTAssertTrue(entries.allSatisfy { !$0.items.isEmpty }, "a changelog version has no bullets")
    }
}
