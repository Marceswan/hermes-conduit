import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ConduitMac

@MainActor
final class ComposerPasteTextViewTests: XCTestCase {
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards.removeAll()
        super.tearDown()
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        boards.append(pb)
        return pb
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return image.pngData()!
    }

    func testBitmapPasteBecomesPastedImage() {
        let pb = board()
        pb.clearContents()
        pb.setData(pngData(), forType: .png)
        let images = ComposerTextView.pastedImages(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    func testFileURLImagePasteBecomesPastedImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = board()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        let images = ComposerTextView.pastedImages(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    func testPlainTextPasteIsNotAnImage() {
        let pb = board()
        pb.clearContents()
        pb.setString("hi", forType: .string)
        XCTAssertTrue(ComposerTextView.pastedImages(from: pb).isEmpty)
    }

    func testReturnSubmitsWhenAllowed() {
        let view = ComposerTextView()
        var submitted = false
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { submitted = true; return true }
        XCTAssertTrue(view.handleReturn(shift: false))
        XCTAssertTrue(submitted)
    }

    func testShiftReturnInsertsNewline() {
        let view = ComposerTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { XCTFail("must not submit"); return true }
        XCTAssertFalse(view.handleReturn(shift: true))
    }

    func testOptionReturnIsANewlineModifier() {
        XCTAssertTrue(ComposerTextView.isNewlineModifier([.option]))
        XCTAssertTrue(ComposerTextView.isNewlineModifier([.shift]))
        XCTAssertFalse(ComposerTextView.isNewlineModifier([]))
        XCTAssertFalse(ComposerTextView.isNewlineModifier([.numericPad, .function]))
    }

    private func makeWindow(hosting view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    func testFocusChangeCallbacksFollowFirstResponder() {
        let view = ComposerTextView()
        let window = makeWindow(hosting: view)
        defer { window.close() }
        var events: [Bool] = []
        view.onFocusChange = { events.append($0) }

        window.makeFirstResponder(view)
        XCTAssertEqual(events, [true])
        window.makeFirstResponder(nil)
        XCTAssertEqual(events, [true, false])
    }

    func testWantsFocusIsHonouredWhenViewEntersWindow() {
        let view = ComposerTextView()
        view.wantsFocus = true
        let window = makeWindow(hosting: view)
        defer { window.close() }
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(view.wantsFocus)
    }

    func testDragTypesIncludeFileURLPNGAndTIFF() {
        let view = ComposerTextView()
        let types = view.registeredDraggedTypes
        XCTAssertTrue(types.contains(.fileURL))
        XCTAssertTrue(types.contains(.png))
        XCTAssertTrue(types.contains(.tiff))
    }

    func testDragOperationAcceptsImageAndDefersText() {
        let view = ComposerTextView()
        let image = board()
        image.clearContents()
        image.setData(pngData(), forType: .png)
        XCTAssertEqual(view.dragOperation(for: image), .copy)

        let text = board()
        text.clearContents()
        text.setString("hi", forType: .string)
        XCTAssertEqual(view.dragOperation(for: text), [])
    }

    func testPasteDecisionPrefersTextOverBitmapPreview() {
        let pb = board()
        pb.clearContents()
        pb.setData(pngData(), forType: .png)
        pb.setString("cell A1", forType: .string)
        XCTAssertEqual(ComposerTextView.pasteDecision(for: pb), .text)
    }

    func testPasteDecisionAttachesBitmapOnlyPaste() {
        let pb = board()
        pb.clearContents()
        pb.setData(pngData(), forType: .png)
        guard case .images(let images) = ComposerTextView.pasteDecision(for: pb) else {
            return XCTFail("expected images")
        }
        XCTAssertEqual(images.count, 1)
    }

    func testPasteDecisionKeepsImageFileURLWithFilenameString() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = board()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setString(url.lastPathComponent, forType: .string)
        guard case .images(let images) = ComposerTextView.pasteDecision(for: pb) else {
            return XCTFail("expected images")
        }
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    // MARK: Attachment limit before the read (review M10)

    /// A PNG-named file of `bytes` bytes; sparse, so a large one costs nothing to make or to refuse.
    private func imageFile(bytes: UInt64) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: pngData()))
        let handle = try FileHandle(forWritingTo: url)
        if bytes > UInt64(pngData().count) { try handle.truncate(atOffset: bytes) }
        try handle.close()
        return url
    }

    private func boardWith(_ url: URL) -> NSPasteboard {
        let pb = board()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setString(url.lastPathComponent, forType: .string)
        return pb
    }

    func testImageFileOverTheLimitIsNotReadAndIsNamed() throws {
        let url = try imageFile(bytes: 3 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = boardWith(url)
        XCTAssertTrue(ComposerTextView.imageFileImages(from: pb, megabytes: 1).isEmpty)
        XCTAssertEqual(ComposerTextView.oversizeImageFileNames(from: pb, megabytes: 1), [url.lastPathComponent])
    }

    func testImageFileWithinTheLimitIsStillRead() throws {
        let url = try imageFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = boardWith(url)
        XCTAssertEqual(ComposerTextView.imageFileImages(from: pb, megabytes: 1).count, 1)
        XCTAssertTrue(ComposerTextView.oversizeImageFileNames(from: pb, megabytes: 1).isEmpty)
    }

    func testAnOversizeFileIsReportedWithTheLimitAndItsName() throws {
        let url = try imageFile(bytes: 3 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var messages: [String] = []
        view.onPastedImageError = { messages.append($0) }
        XCTAssertTrue(view.reportOversizeImageFiles(on: boardWith(url), megabytes: 1))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains(url.lastPathComponent), messages[0])
        XCTAssertTrue(messages[0].contains("1 MB"), messages[0])

        let small = try imageFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: small) }
        XCTAssertFalse(view.reportOversizeImageFiles(on: boardWith(small), megabytes: 1), "nothing to report for a small file")
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: A file over the limit next to an accepted one (re-review Minor 2)

    /// Sets the attachment limit for the test (the paste path reads it from the defaults) and restores it.
    private func withLimit(megabytes: Int, _ body: () throws -> Void) rethrows {
        let key = AttachmentSizeLimit.preferenceKey
        let snapshot = StandardDefaultsSnapshot(keys: [key])
        defer { snapshot.restore() }
        UserDefaults.standard.set(megabytes, forKey: key)
        try body()
    }

    private func boardWith(_ urls: [URL]) -> NSPasteboard {
        let pb = board()
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        return pb
    }

    func testMixedPasteAttachesTheSmallFileAndReportsTheLargeOne() throws {
        let small = try imageFile(bytes: 0)
        let large = try imageFile(bytes: 3 * 1024 * 1024)
        defer { [small, large].forEach { try? FileManager.default.removeItem(at: $0) } }
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var attached: [PastedImage] = []
        var messages: [String] = []
        view.onPastedImages = { attached += $0 }
        view.onPastedImageError = { messages.append($0) }
        withLimit(megabytes: 1) {
            view.performPaste(from: boardWith([small, large]), sender: nil)
        }
        XCTAssertEqual(attached.count, 1, "the small file is attached")
        XCTAssertEqual(messages.count, 1, "the large file is reported: \(messages)")
        XCTAssertTrue(messages.first?.contains(large.lastPathComponent) == true, "\(messages)")
        XCTAssertFalse(messages.first?.contains(small.lastPathComponent) == true, "the accepted file is not named")
    }

    func testPasteWithOnlySmallFilesReportsNothing() throws {
        let small = try imageFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: small) }
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var attached = 0
        var messages: [String] = []
        view.onPastedImages = { attached += $0.count }
        view.onPastedImageError = { messages.append($0) }
        withLimit(megabytes: 1) { view.performPaste(from: boardWith([small]), sender: nil) }
        XCTAssertEqual(attached, 1)
        XCTAssertTrue(messages.isEmpty)
    }

    func testMixedDropAttachesTheSmallFileAndReportsTheLargeOne() throws {
        let small = try imageFile(bytes: 0)
        let large = try imageFile(bytes: 3 * 1024 * 1024)
        defer { [small, large].forEach { try? FileManager.default.removeItem(at: $0) } }
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var attached = 0
        var messages: [String] = []
        view.onPastedImages = { attached += $0.count }
        view.onPastedImageError = { messages.append($0) }
        var handled = false
        withLimit(megabytes: 1) { handled = view.performImageDrop(from: boardWith([small, large])) }
        XCTAssertTrue(handled)
        XCTAssertEqual(attached, 1)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.contains(large.lastPathComponent) == true, "\(messages)")
    }

    func testDropOfOnlyALargeFileIsOursAndReported() throws {
        let large = try imageFile(bytes: 3 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: large) }
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var attached = 0
        var messages: [String] = []
        view.onPastedImages = { attached += $0.count }
        view.onPastedImageError = { messages.append($0) }
        var handled = false
        withLimit(megabytes: 1) { handled = view.performImageDrop(from: boardWith([large])) }
        XCTAssertTrue(handled)
        XCTAssertEqual(attached, 0)
        XCTAssertEqual(messages.count, 1)
    }

    func testReturnDuringMarkedTextDoesNotSubmit() {
        // Hosted in a window so the input context exists and marked text sticks.
        let view = ComposerTextView()
        let window = makeWindow(hosting: view)
        defer { window.close() }
        window.makeFirstResponder(view)
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { XCTFail("must not submit during IME composition"); return true }
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.handleReturn(shift: false))
    }
}
