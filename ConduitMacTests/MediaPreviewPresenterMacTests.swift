import AppKit
import XCTest
@testable import ConduitMac

/// `MediaPreviewPresenter.present(downloaded:)` on Mac (Task 12, Artifacts): a file the gateway
/// sent is quarantined, then revealed in Finder. Upstream's body (shared) picks Quick Look or the
/// share sheet; on Mac both are the same reveal, so a page type Quick Look must not render is
/// revealed, never rendered.
@MainActor
final class MediaPreviewPresenterMacTests: XCTestCase {
    private var root: URL!
    private var revealed: [URL] = []
    private var savedReveal: ((URL) -> Void)!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPreviewPresenterMacTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        revealed = []
        savedReveal = MediaPreviewPresenter.revealInFinder
        MediaPreviewPresenter.revealInFinder = { [unowned self] url in self.revealed.append(url) }
    }

    override func tearDown() async throws {
        MediaPreviewPresenter.revealInFinder = savedReveal
        try? FileManager.default.removeItem(at: root)
    }

    /// A downloaded file in a directory of its own, as `DashboardTicketBridge.downloadFile` leaves it.
    private func download(_ name: String, mimeType: String?, contents: String = "x") throws -> DashboardDownloadedFile {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return DashboardDownloadedFile(directory: directory, file: file, mimeType: mimeType)
    }

    private func quarantine(of url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, 0)
        return read > 0 ? String(decoding: buffer.prefix(read), as: UTF8.self) : nil
    }

    func testDownloadedFileIsQuarantinedAndRevealedInFinder() throws {
        let file = try download("report.pdf", mimeType: "application/pdf")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(revealed, [file.file])
        XCTAssertNotNil(quarantine(of: file.file), "gateway bytes are marked downloaded before Finder shows them")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.file.path), "the file stays for Finder")
    }

    func testAPageIsRevealedNeverRendered() throws {
        let file = try download("chart.html", mimeType: "text/html", contents: "<script>alert(1)</script>")
        XCTAssertFalse(MediaPreviewPresenter.isPreviewable(filename: "chart.html", mimeType: "text/html"))
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(revealed, [file.file])
        XCTAssertNotNil(quarantine(of: file.file))
    }

    func testAFileThatCannotBeMarkedIsNotRevealedAndItsDirectoryGoes() throws {
        let file = try download("notes.txt", mimeType: "text/plain")
        try FileManager.default.removeItem(at: file.file)
        XCTAssertFalse(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path), "the staged directory is removed")
    }
}
