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
