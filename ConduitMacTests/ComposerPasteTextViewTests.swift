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

    func testReturnDuringMarkedTextDoesNotSubmit() {
        let view = ComposerTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { XCTFail("must not submit during IME composition"); return true }
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.handleReturn(shift: false))
    }
}
