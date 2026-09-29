import XCTest
@testable import S1S

/// Guards the in-flight staging measurement that keeps the download watchdog from
/// cancelling healthy multi-GB transfers. `URLSession.download(for:)` streams into a
/// `CFNetworkDownload_*.tmp` and only moves the finished file into the model cache, so
/// without counting these the cache directory shows zero growth for the whole download.
final class ModelStorageTests: XCTestCase {

    private var created: [URL] = []

    override func tearDown() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
        super.tearDown()
    }

    private func makeStagingFile(name: String, bytes: Int, modified: Date) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.path)
        created.append(url)
        return url
    }

    func testCountsStagingFilesModifiedAfterStart() throws {
        let start = Date()
        let before = ModelStorage.inFlightBytes(since: start)
        _ = try makeStagingFile(name: "CFNetworkDownload_unittest_a.tmp",
                                bytes: 4096, modified: start.addingTimeInterval(1))
        XCTAssertEqual(ModelStorage.inFlightBytes(since: start), before + 4096)
    }

    func testIgnoresStagingFilesFromEarlierRuns() throws {
        let start = Date()
        _ = try makeStagingFile(name: "CFNetworkDownload_unittest_old.tmp",
                                bytes: 8192, modified: start.addingTimeInterval(-600))
        XCTAssertEqual(ModelStorage.inFlightBytes(since: start), 0,
                       "a staging file left by an earlier run must not count as progress")
    }

    func testIgnoresUnrelatedTempFiles() throws {
        let start = Date()
        _ = try makeStagingFile(name: "s1s_unittest_unrelated.tmp",
                                bytes: 4096, modified: start.addingTimeInterval(1))
        XCTAssertEqual(ModelStorage.inFlightBytes(since: start), 0)
    }
}
