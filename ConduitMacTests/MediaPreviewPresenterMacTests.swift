import AppKit
import PDFKit
import XCTest
@testable import ConduitMac

/// `MediaPreviewPresenter` on Mac (D34). Upstream's body (shared) picks Quick Look or the share
/// sheet; on Mac both land in one sheet inside Conduit. Finder is the last resort, for when no
/// window can hold the sheet.
@MainActor
final class MediaPreviewPresenterMacTests: XCTestCase {
    private var root: URL!
    private var revealed: [URL] = []
    private var savedReveal: ((URL) -> Void)!
    private var previews: [MacFilePreview] = []
    /// What the swapped sheet answers: false when no window can hold the preview.
    private var previewResult = true
    private var savedPresentPreview: ((MacFilePreview) -> Bool)!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPreviewPresenterMacTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        revealed = []
        savedReveal = MediaPreviewPresenter.revealInFinder
        MediaPreviewPresenter.revealInFinder = { [unowned self] url in self.revealed.append(url) }
        previews = []
        previewResult = true
        savedPresentPreview = MediaPreviewPresenter.presentPreview
        MediaPreviewPresenter.presentPreview = { [unowned self] preview in
            self.previews.append(preview)
            return self.previewResult
        }
    }

    override func tearDown() async throws {
        MediaPreviewPresenter.revealInFinder = savedReveal
        MediaPreviewPresenter.presentPreview = savedPresentPreview
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

    // MARK: every kind of file opens in Conduit

    func testAMediaOrDocumentFileOpensInQuickLookNotFinder() throws {
        for (name, mime) in [("map.png", "image/png"), ("clip.mp4", "video/mp4"), ("note.m4a", "audio/mp4"),
                             ("brief.docx", nil), ("sheet.xlsx", nil), ("deck.pptx", nil), ("deck.key", nil),
                             ("data.csv", "text/csv")] as [(String, String?)] {
            previews = []
            let file = try download(name, mimeType: mime)
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file), name)
            XCTAssertEqual(previews, [MacFilePreview(name: name, file: file.file, ownedDirectory: file.directory,
                                                     content: .quickLook)], name)
            XCTAssertTrue(revealed.isEmpty, "\(name): the user stays in Conduit")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.file.path), "\(name): Quick Look reads the file")
        }
    }

    func testAGatewayFileIsQuarantinedBeforeItIsPreviewed() throws {
        let file = try download("report.pdf", mimeType: "application/pdf")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertNotNil(quarantine(of: file.file), "gateway bytes are marked downloaded before anything reads them")
    }

    func testAFileThatCannotBeMarkedOpensNothingAndItsDirectoryGoes() throws {
        let file = try download("notes.txt", mimeType: "text/plain")
        try FileManager.default.removeItem(at: file.file)
        XCTAssertFalse(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertTrue(previews.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path), "the staged directory is removed")
    }

    func testAFileInPlaceIsMarkedAndNotOwned() throws {
        // A local attachment or a cached gateway picture: the path does not tell which, so it is marked.
        let file = try download("mine.md", mimeType: nil, contents: "mine").file
        // The app's own writes can carry a mark from the system; this file starts with none.
        removexattr(file.path, "com.apple.quarantine", 0)
        XCTAssertNil(quarantine(of: file))
        XCTAssertTrue(MediaPreviewPresenter().present(fileURL: file, title: "Shown name"))
        XCTAssertEqual(previews, [MacFilePreview(name: "Shown name", file: file, ownedDirectory: nil, content: .markdown("mine"))])
        XCTAssertNotNil(quarantine(of: file))
    }

    func testAFileInPlaceThatCannotBeMarkedStillPreviews() throws {
        let file = try download("mine.md", mimeType: nil, contents: "mine").file
        removexattr(file.path, "com.apple.quarantine", 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        XCTAssertTrue(MediaPreviewPresenter().present(fileURL: file, title: "mine.md"))
        XCTAssertEqual(previews.first?.content, .markdown("mine"), "reading it in the sheet opens nothing else")
        XCTAssertNil(quarantine(of: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testWithNoWindowToHoldThePreviewTheFileGoesToFinder() throws {
        previewResult = false
        let file = try download("report.pdf", mimeType: "application/pdf")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(revealed, [file.file], "the file still opens")
        XCTAssertNotNil(quarantine(of: file.file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.file.path), "the file stays for Finder")
    }

    // MARK: what draws how

    func testMarkdownDrawsAsMarkdown() throws {
        let file = try download("notes.MD", mimeType: "text/markdown", contents: "# Title\n\nBody")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .markdown("# Title\n\nBody"))
    }

    func testAPageDrawsInTheSandboxedWebViewNeverQuickLook() throws {
        for name in ["chart.html", "chart.HTM", "chart.xhtml"] {
            previews = []
            let file = try download(name, mimeType: "text/html", contents: "<p>hello</p>")
            XCTAssertFalse(MediaPreviewPresenter.isPreviewable(filename: name, mimeType: "text/html"))
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file), name)
            XCTAssertEqual(previews.first?.content, .html("<p>hello</p>"), name)
        }
    }

    func testAnSVGDrawsInTheSandboxedWebViewNeverQuickLook() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"/></svg>"
        let file = try download("logo.svg", mimeType: "image/svg+xml", contents: svg)
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .html(svg))
    }

    func testATextFileQuickLookMayOnlyDrawAsAnIconShowsItsText() throws {
        for name in ["notes.txt", "config.yaml", "config.yml", "data.json", "run.log", "sam.vcf", "trip.ics", "route.gpx",
                     "place.kml", "data.tsv", "script.py", "settings.toml", "Makefile", "archive.unknownext"] {
            previews = []
            let file = try download(name, mimeType: nil, contents: "key: value")
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file), name)
            XCTAssertEqual(previews.first?.content, .text("key: value"), name)
        }
    }

    func testATextFileWithBinaryBytesHasNoPreview() throws {
        for bytes in [Data([0xFF, 0xFE, 0xFA]), Data([0x61, 0x00, 0x62])] {
            previews = []
            let file = try download("run.log", mimeType: nil)
            try bytes.write(to: file.file)
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
            XCTAssertEqual(previews.first?.content, .unavailable, "\(bytes as NSData)")
        }
    }

    // MARK: Quick Look gets only what is on its list

    func testATypeNotOnTheListNeverReachesQuickLook() throws {
        // None is on upstream's list, and Quick Look would draw or follow each of them.
        for name in ["mail.eml", "mail.emlx", "box.mbox", "place.webloc", "link.url", "settings.plist", "book.epub",
                     "bundle.zip", "backup.tgz", "logo.eps", "blob.unknownext"] {
            previews = []
            let file = try download(name, mimeType: nil)
            try Data([0xFF, 0xFE, 0x00]).write(to: file.file)
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file), name)
            XCTAssertEqual(previews.first?.content, .unavailable, name)
            XCTAssertTrue(revealed.isEmpty, name)
        }
    }

    func testAMailMessageShowsItsTextNeverItsRenderedBody() throws {
        let file = try download("mail.eml", mimeType: nil, contents: "Subject: x\n\n<html><img src=https://t.example/a></html>")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .text("Subject: x\n\n<html><img src=https://t.example/a></html>"))
    }

    func testWebContentUnderADocumentNameNeverReachesQuickLook() throws {
        for (name, body) in [("brief.doc", "<html><script>alert(1)</script></html>"), ("photo.png", "<!DOCTYPE HTML><p>x"),
                             ("sheet.xlsx", "<svg onload=alert(1)>"), ("data.csv", "a,<script>alert(1)</script>")] {
            previews = []
            let file = try download(name, mimeType: nil, contents: body)
            XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file), name)
            XCTAssertEqual(previews.first?.content, .text(body), "\(name): as text, so nothing runs")
        }
    }

    // MARK: PDF and RTF, whose links pass the app's policy

    func testAPDFDrawsInPDFKitNotQuickLook() throws {
        let file = try download("report.pdf", mimeType: "application/pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertTrue(document.write(to: file.file))
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .pdf)
    }

    func testABrokenPDFIsNeverHandedToQuickLook() throws {
        let file = try download("report.pdf", mimeType: "application/pdf")
        try Data([0xFF, 0xFE, 0xFA]).write(to: file.file)
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .unavailable)
    }

    func testRTFDrawsAsRichTextNotQuickLook() throws {
        let rich = NSAttributedString(string: "Styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let data = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length)))
        let file = try download("brief.rtf", mimeType: "application/rtf")
        try data.write(to: file.file)
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        guard case .richText(let drawn)? = previews.first?.content else {
            return XCTFail("\(String(describing: previews.first?.content))")
        }
        XCTAssertEqual(drawn.string, "Styled")
    }

    func testXMLShowsAsTextNeverQuickLook() throws {
        let file = try download("feed.xml", mimeType: "text/xml", contents: "<a><b/></a>")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .text("<a><b/></a>"))
    }

    func testAFileWhoseTypeSaysItIsAWebPageNeverReachesQuickLook() throws {
        // Named as a PDF, served as HTML: upstream's policy refuses it by its MIME type.
        let file = try download("report.pdf", mimeType: "text/html", contents: "<script>alert(1)</script>")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .text("<script>alert(1)</script>"), "as text, so nothing runs")
    }

    func testABinaryWebArchiveHasNoPreviewButTheSheetStillOpens() throws {
        let file = try download("saved.webarchive", mimeType: nil)
        try Data([0xFF, 0xFE, 0xFA]).write(to: file.file)
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .unavailable)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testAPageThatIsNotUTF8HasNoPreview() throws {
        let file = try download("old.html", mimeType: "text/html")
        try Data([0xFF, 0xFE, 0xFA]).write(to: file.file)
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: file))
        XCTAssertEqual(previews.first?.content, .unavailable, "these bytes would draw as garbage")
    }

    func testAMarkdownFileThatCannotDrawHasNoPreview() throws {
        let blank = try download("blank.md", mimeType: nil, contents: " \n\t\n")
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: blank))
        XCTAssertEqual(previews.last?.content, .unavailable)

        let huge = try download("huge.md", mimeType: nil)
        let handle = try FileHandle(forWritingTo: huge.file)
        try handle.truncate(atOffset: UInt64(MacFilePreview.maximumTextBytes) + 1)
        try handle.close()
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: huge))
        XCTAssertEqual(previews.last?.content, .unavailable)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testAPageOverTheLimitHasNoPreview() throws {
        let huge = try download("huge.html", mimeType: "text/html")
        let handle = try FileHandle(forWritingTo: huge.file)
        try handle.truncate(atOffset: UInt64(MacFilePreview.maximumTextBytes) + 1)
        try handle.close()
        XCTAssertTrue(MediaPreviewPresenter().present(downloaded: huge))
        XCTAssertEqual(previews.last?.content, .unavailable)
    }

    func testAPageFromADataURLOpensUnderItsOwnName() async throws {
        let dataURL = "data:text/html;base64," + Data("<p>hello</p>".utf8).base64EncodedString()
        let presented = await MediaPreviewPresenter().present(dataURL: dataURL, filename: "/root/out/chart.html")
        XCTAssertTrue(presented)
        XCTAssertEqual(previews.first?.name, "chart.html")
        XCTAssertEqual(previews.first?.content, .html("<p>hello</p>"))
        XCTAssertTrue(revealed.isEmpty)
    }
}
