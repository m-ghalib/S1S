import XCTest
@testable import TabType

/// Guards the post-download size check. It once reported a full-size file as
/// "stopped early" because `URL.resourceValues` returned the size cached at resume start.
final class ModelDownloaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabtype-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func append(_ count: Int, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: count))
        try handle.close()
    }

    func testFileSizeIsNotCachedPerURL() throws {
        let partial = dir.appendingPathComponent("model.safetensors.partial")
        FileManager.default.createFile(atPath: partial.path, contents: Data(count: 10))
        XCTAssertEqual(ModelDownloader.fileSize(partial), 10)   // read at "resume start"
        try append(90, to: partial)
        XCTAssertEqual(ModelDownloader.fileSize(partial), 100)
    }

    func testFullSizePartialPublishesWithoutError() throws {
        let file = ModelDownloader.RemoteFile(name: "model.safetensors", size: 100)
        let partial = dir.appendingPathComponent("model.safetensors.partial")
        let destination = dir.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: partial.path, contents: Data(count: 40))
        _ = ModelDownloader.fileSize(partial)   // same URL sized before the transfer, as in download()
        try append(60, to: partial)

        XCTAssertEqual(try ModelDownloader.publish(file: file, partial: partial, destination: destination), 100)
        XCTAssertEqual(ModelDownloader.fileSize(destination), 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testShortPartialThrowsIncompleteAndIsKept() throws {
        let file = ModelDownloader.RemoteFile(name: "model.safetensors", size: 100)
        let partial = dir.appendingPathComponent("model.safetensors.partial")
        let destination = dir.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: partial.path, contents: Data(count: 40))

        XCTAssertThrowsError(try ModelDownloader.publish(file: file, partial: partial, destination: destination)) { error in
            guard case ModelDownloader.Failure.incomplete(_, let expected, let got) = error else {
                return XCTFail("expected .incomplete, got \(error)")
            }
            XCTAssertEqual(expected, 100)
            XCTAssertEqual(got, 40)
        }
        XCTAssertEqual(ModelDownloader.fileSize(partial), 40)   // kept for resume
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
