import AppKit
import Quartz
import SwiftUI
import WebKit
import XCTest
@testable import ConduitMac

/// A file drawn in a sheet of its own (D34): the sheet `MediaPreviewPresenter` opens over whatever
/// window the user clicked in, without a SwiftUI view to hang it on.
@MainActor
final class MacFilePreviewSheetTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var root: URL!
    private var boostWasOn = false
    private var revealed: [URL] = []
    private var savedReveal: ((URL) -> Void)!

    override func setUp() async throws {
        boostWasOn = AccessibilityTreeBoost.isOn
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFilePreviewSheetTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        revealed = []
        savedReveal = MediaPreviewPresenter.revealInFinder
        MediaPreviewPresenter.revealInFinder = { [unowned self] in self.revealed.append($0) }
    }

    override func tearDown() async throws {
        MediaPreviewPresenter.revealInFinder = savedReveal
        AccessibilityTreeBoost.set(boostWasOn)
        for window in windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            HostedTestSupport.tearDown(window)
        }
        windows = []
        try? FileManager.default.removeItem(at: root)
    }

    private func parent() -> NSWindow {
        let window = HostedTestSupport.host(Color.clear, size: NSSize(width: 900, height: 700))
        windows.append(window)
        return window
    }

    /// A staged file in a directory of its own, and the preview of it.
    private func preview(_ name: String = "notes.md", _ content: MacFilePreview.Content = .markdown("# Release notes\n\nBody text"),
                         owned: Bool = true) throws -> MacFilePreview {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return MacFilePreview(name: name, file: file, ownedDirectory: owned ? directory : nil, content: content)
    }

    /// A click in the middle of the window's content.
    private func click(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.midY),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    // MARK: what it draws

    func testMarkdownDrawsInASheetUnderTheFileName() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        func texts() -> [String] { AccessibilityProbe.texts(in: sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { texts().contains { $0.contains("Release notes") } }, "\(texts())")
        XCTAssertTrue(texts().contains { $0.contains("notes.md") }, "\(texts())")
    }

    func testHTMLDrawsInAWebViewThatRunsTheFile() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(
            try preview("chart.html", .html("<title>Sales chart</title><p>hello</p>")), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(WKWebView.self, in: sheet.contentView) != nil })
        let web = try XCTUnwrap(find(WKWebView.self, in: sheet.contentView))
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { web.title == "Sales chart" },
                      "title: \(String(describing: web.title))")
    }

    func testAMediaFileDrawsInQuickLookFromItsFile() throws {
        let window = parent()
        let item = try preview("report.pdf", .quickLook)
        XCTAssertTrue(MacFilePreviewSheet.present(item, over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(QLPreviewView.self, in: sheet.contentView) != nil })
        let quickLook = try XCTUnwrap(find(QLPreviewView.self, in: sheet.contentView))
        XCTAssertEqual(quickLook.previewItem?.previewItemURL, item.file)
        XCTAssertFalse(quickLook.autostarts, "a video or a clip waits for the user")
    }

    func testTextDrawsInASelectableViewThatCannotBeEdited() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("feed.xml", .text("<a><b/></a>")), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(NSTextView.self, in: sheet.contentView)?.string == "<a><b/></a>" })
        let text = try XCTUnwrap(find(NSTextView.self, in: sheet.contentView))
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
    }

    func testAFileWithNoPreviewSaysSoAndOffersFinder() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("saved.webarchive", .unavailable), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        func texts() -> [String] { AccessibilityProbe.texts(in: sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { texts().contains { $0.contains("preview file") } }, "\(texts())")
        XCTAssertTrue(AccessibilityProbe.labels(in: sheet).contains("Show in Finder"),
                      "\(AccessibilityProbe.labels(in: sheet))")
    }

    // MARK: links

    func testALinkInMarkdownPassesTheAppsLinkPolicy() throws {
        let window = parent()
        var routed: [URL] = []
        let links = MacFilePreviewLinks(routeWidgetLaunch: { routed.append($0); return true }, openAppLink: { _ in })
        // No app claims this scheme, so the default action of an unguarded view does nothing visible.
        let url = try XCTUnwrap(URL(string: "conduit-preview-test://link"))
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("notes.md", .markdown("[link](\(url.absoluteString))")),
                                                  over: window, links: links))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(NSTextView.self, in: sheet.contentView) != nil })
        let text = try XCTUnwrap(find(NSTextView.self, in: sheet.contentView))
        _ = text.delegate?.textView?(text, clickedOnLink: url, at: 0)
        XCTAssertEqual(routed, [url], "gateway-controlled links do not reach SwiftUI's default action")
    }

    // MARK: closing, whatever the file shows

    func testAPageWithItsOwnCloseButtonCannotTakeTheSheetsWayOut() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("form.html", .html(
            "<title>Form</title><button>Close</button><button>Cancel</button><button>Done</button>")), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.find(WKWebView.self, in: sheet.contentView) != nil })
        let web = try XCTUnwrap(find(WKWebView.self, in: sheet.contentView))
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 10) { web.title == "Form" })
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(SheetCloseButton.isContentSheet(sheet))
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(sheet), "the X is the app's, so the file cannot remove it")
        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
    }

    // MARK: the sheet

    func testAClickOnTheWindowBehindANestedPreviewClosesOnlyThePreview() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let list = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("second.md"), over: window))
        let top = try XCTUnwrap(list.attachedSheet)
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(top))
        XCTAssertTrue(SheetCloseButton.handleOutsideClick(try click(in: window)), "the click is not ignored")
        XCTAssertTrue(HostedTestSupport.waitUntil { list.attachedSheet == nil })
        XCTAssertTrue(window.attachedSheet === list, "Show as List stays under it")
    }

    func testAClickBehindAFormOverAPreviewIsLeftAlone() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let preview = try XCTUnwrap(window.attachedSheet)
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(preview))
        let form = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                            backing: .buffered, defer: false)
        form.isReleasedWhenClosed = false
        preview.beginSheet(form)
        XCTAssertFalse(SheetCloseButton.handleOutsideClick(try click(in: window)),
                       "a stray click never throws away a half-filled form")
        XCTAssertTrue(preview.attachedSheet === form)
        preview.endSheet(form)
    }

    func testTheSheetUsesTheAppsLanguageNotTheSystems() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        preserveStandardDefaults(AppLanguageStore.defaultsKey)
        let store = AppLanguageStore.shared
        let previous = store.selection
        store.select(try XCTUnwrap(AppLanguage(rawValue: "de")))
        addTeardownBlock { @MainActor in store.select(previous) }
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("saved.webarchive", .unavailable), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        func texts() -> [String] { AccessibilityProbe.texts(in: sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { texts().contains { $0.contains("Vorschau der Datei") } }, "\(texts())")
        XCTAssertTrue(AccessibilityProbe.labels(in: sheet).contains("Im Finder anzeigen"),
                      "\(AccessibilityProbe.labels(in: sheet))")
    }

    func testTheSheetOpensAtAReadableSizeAndCanGrow() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        HostedTestSupport.settle(0.2)
        XCTAssertGreaterThanOrEqual(sheet.frame.width, 560, "\(sheet.frame)")
        XCTAssertGreaterThanOrEqual(sheet.frame.height, 420, "\(sheet.frame)")
        XCTAssertTrue(sheet.styleMask.contains(.resizable))
    }

    func testTheSheetFollowsTheLookOfItsWindow() throws {
        let window = parent()
        window.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    func testEscClosesTheSheet() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(sheet), "the sheet gets the X every Mac sheet has")
        XCTAssertTrue(SheetEscape.handleEscape(in: sheet))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
    }

    func testAClickBehindTheSheetClosesIt() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(SheetCloseButton.decorateIfNeeded(sheet))
        XCTAssertTrue(SheetCloseButton.handleOutsideClick(try click(in: window)))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
    }

    func testItOpensOverASheetAlreadyOpen() throws {
        let window = parent()
        XCTAssertTrue(MacFilePreviewSheet.present(try preview(), over: window))
        let first = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(MacFilePreviewSheet.present(try preview("second.md"), over: window))
        XCTAssertNotNil(first.attachedSheet, "the Show as List sheet stays under the preview")
        first.endSheet(try XCTUnwrap(first.attachedSheet))
    }

    func testTheKeyWindowHoldsThePreviewElseTheMainWindow() {
        let key = parent()
        let main = parent()
        XCTAssertTrue(MacFilePreviewSheet.host(key: key, main: main) === key)
        XCTAssertTrue(MacFilePreviewSheet.host(key: nil, main: main) === main)
        XCTAssertNil(MacFilePreviewSheet.host(key: nil, main: nil))
    }

    func testWithNoWindowItSaysSoAndTheCallerFallsBack() throws {
        XCTAssertFalse(MacFilePreviewSheet.present(try preview(), over: nil))
    }

    // MARK: the staged file

    func testClosingTheSheetRemovesTheStagedCopy() throws {
        let window = parent()
        let item = try preview("report.pdf", .quickLook)
        let directory = try XCTUnwrap(item.ownedDirectory)
        XCTAssertTrue(MacFilePreviewSheet.present(item, over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.file.path), "the open preview reads it")
        sheet.cancelOperation(nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { !FileManager.default.fileExists(atPath: directory.path) })
    }

    func testClosingTheSheetLeavesALocalFileInPlace() throws {
        let window = parent()
        let item = try preview("mine.pdf", .quickLook, owned: false)
        XCTAssertTrue(MacFilePreviewSheet.present(item, over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.cancelOperation(nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.file.path))
    }

    func testShowInFinderRevealsNothingWhenTheFileCannotBeMarked() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let window = parent()
        let item = try preview("bundle.zip", .quickLook)
        removexattr(item.file.path, "com.apple.quarantine", 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: item.file.path)
        XCTAssertTrue(MacFilePreviewSheet.present(item, over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: sheet).contains("Show in Finder") })
        XCTAssertTrue(AccessibilityProbe.press("Show in Finder", in: sheet))
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(revealed.isEmpty)
        sheet.cancelOperation(nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { !FileManager.default.fileExists(atPath: item.file.path) },
                      "not revealed, so the staged copy goes with the sheet")
    }

    func testShowInFinderRevealsTheFileAndKeepsItAfterTheSheetCloses() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let window = parent()
        let item = try preview("bundle.zip", .quickLook)
        XCTAssertTrue(MacFilePreviewSheet.present(item, over: window))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: sheet).contains("Show in Finder") },
                      "\(AccessibilityProbe.labels(in: sheet))")
        XCTAssertTrue(AccessibilityProbe.press("Show in Finder", in: sheet))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.revealed == [item.file] }, "\(revealed)")
        XCTAssertGreaterThan(getxattr(item.file.path, "com.apple.quarantine", nil, 0, 0, 0), 0,
                             "marked before Finder shows it, as the file may be a cached gateway file")
        sheet.cancelOperation(nil)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.file.path), "Finder still shows it")
    }
}
