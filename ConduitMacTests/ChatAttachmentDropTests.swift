import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import ConduitMac

@MainActor
final class ChatAttachmentDropTests: XCTestCase {
    private var boards: [NSPasteboard] = []
    private var scratch: [URL] = []

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards.removeAll()
        scratch.forEach { try? FileManager.default.removeItem(at: $0) }
        scratch.removeAll()
        super.tearDown()
    }

    // MARK: Fixtures

    private func board() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        boards.append(pb)
        pb.clearContents()
        return pb
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return image.pngData()!
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    @discardableResult
    private func touch(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func sink(enabled: Bool, received: @escaping (MacAttachmentDropPayload) -> Void = { _ in }) -> MacAttachmentDropSink {
        let sink = MacAttachmentDropSink()
        sink.receiver = MacAttachmentDropReceiver(isEnabled: { enabled }, receive: received)
        return sink
    }

    // MARK: Payload

    func testFileURLsOnPasteboardBecomeFilePayload() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])
        XCTAssertEqual(MacAttachmentDropPolicy.payload(from: pb), .fileURLs([file]))
    }

    func testRawImageDataWithoutFileURLBecomesImagePayload() {
        let pb = board()
        pb.setData(pngData(), forType: .png)
        guard case .images(let images)? = MacAttachmentDropPolicy.payload(from: pb) else {
            return XCTFail("expected an image payload")
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.typeIdentifier, UTType.png.identifier)
    }

    func testFileURLWinsOverImageData() throws {
        let dir = try makeDirectory()
        let file = try touch("pic.png", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])
        pb.setData(pngData(), forType: .png)
        XCTAssertEqual(MacAttachmentDropPolicy.payload(from: pb), .fileURLs([file]))
    }

    func testPlainTextIsNotAttachable() {
        let pb = board()
        pb.setString("hello", forType: .string)
        XCTAssertNil(MacAttachmentDropPolicy.payload(from: pb))
        XCTAssertFalse(MacAttachmentDropPolicy.hasAttachableContent(pb))
    }

    // MARK: Folder expansion and the cap

    func testFolderExpandsToTopLevelFilesOnly() throws {
        let dir = try makeDirectory()
        try touch("b.txt", in: dir)
        try touch("a.txt", in: dir)
        try touch(".hidden", in: dir)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try touch("nested.txt", in: sub)

        let expansion = MacAttachmentDropPolicy.expand([dir], existingCount: 0, cap: 10)
        XCTAssertEqual(expansion.urls.map(\.lastPathComponent), ["a.txt", "b.txt"])
        XCTAssertEqual(expansion.overflow, 0)
    }

    func testFolderExpansionStopsAtTheCapAndCountsOverflow() throws {
        let dir = try makeDirectory()
        for index in 1...5 { try touch("f\(index).txt", in: dir) }

        let expansion = MacAttachmentDropPolicy.expand([dir], existingCount: 0, cap: 3)
        XCTAssertEqual(expansion.urls.map(\.lastPathComponent), ["f1.txt", "f2.txt", "f3.txt"])
        XCTAssertEqual(expansion.overflow, 2)
    }

    func testExistingAttachmentsUseUpTheCap() throws {
        let dir = try makeDirectory()
        for index in 1...3 { try touch("f\(index).txt", in: dir) }

        let partly = MacAttachmentDropPolicy.expand([dir], existingCount: 2, cap: 3)
        XCTAssertEqual(partly.urls.map(\.lastPathComponent), ["f1.txt"])
        XCTAssertEqual(partly.overflow, 2)

        let full = MacAttachmentDropPolicy.expand([dir], existingCount: 3, cap: 3)
        XCTAssertTrue(full.urls.isEmpty)
        XCTAssertEqual(full.overflow, 3)
    }

    func testLooseFilesAndFoldersShareOneCap() throws {
        let dir = try makeDirectory()
        let loose = try touch("loose.txt", in: dir)
        let folder = try makeDirectory()
        try touch("x.txt", in: folder)
        try touch("y.txt", in: folder)

        let expansion = MacAttachmentDropPolicy.expand([loose, folder], existingCount: 0, cap: 2)
        XCTAssertEqual(expansion.urls.map(\.lastPathComponent), ["loose.txt", "x.txt"])
        XCTAssertEqual(expansion.overflow, 1)
    }

    private func makePackage(_ name: String, in dir: URL) throws -> URL {
        let pkg = dir.appendingPathComponent(name, isDirectory: true)
        let contents = pkg.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try touch("Info.plist", in: contents)
        return pkg
    }

    func testDroppedPackageIsRefusedNotExpandedOrAttached() throws {
        let dir = try makeDirectory()
        let app = try makePackage("Tool.app", in: dir)
        let loose = try touch("keep.txt", in: dir)

        let expansion = MacAttachmentDropPolicy.expand([app, loose], existingCount: 0, cap: 10)
        XCTAssertEqual(expansion.urls, [loose])
        XCTAssertEqual(expansion.packages, ["Tool.app"])
        XCTAssertEqual(expansion.overflow, 0)
    }

    func testRouterReportsDroppedPackagesOnceAndAttachesNothingForThem() throws {
        let dir = try makeDirectory()
        let app = try makePackage("Tool.app", in: dir)
        let rtfd = try makePackage("Note.rtfd", in: dir)

        var attached = false
        var reported: [[String]] = []
        MacAttachmentDropRouter.route(
            .fileURLs([app, rtfd]), existingCount: 0, cap: 10,
            attachFiles: { _ in attached = true },
            attachImage: { _ in },
            overflow: { _ in XCTFail("a package is not overflow") },
            packages: { reported.append($0) }
        )
        XCTAssertFalse(attached)
        XCTAssertEqual(reported, [["Tool.app", "Note.rtfd"]])
    }

    func testFolderSkipsNestedPackagesSymlinksAndHiddenFiles() throws {
        let dir = try makeDirectory()
        let outside = try makeDirectory()
        let secret = try touch("secret.txt", in: outside)
        try touch("real.txt", in: dir)
        try touch(".DS_Store", in: dir)
        try makePackage("Inner.app", in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linkdir"), withDestinationURL: outside)

        let expansion = MacAttachmentDropPolicy.expand([dir], existingCount: 0, cap: 10)
        XCTAssertEqual(expansion.urls.map(\.lastPathComponent), ["real.txt"])
        XCTAssertTrue(expansion.packages.isEmpty, "a nested package is skipped like a subfolder, not reported")
    }

    // MARK: Router: same entry point as the picker

    func testDroppedFilesReachTheSameEntryPointAsPickedFiles() throws {
        let dir = try makeDirectory()
        let one = try touch("one.txt", in: dir)
        let two = try touch("two.pdf", in: dir)

        var attached: [[URL]] = []
        var images: [PastedImage] = []
        var overflow: [Int] = []
        MacAttachmentDropRouter.route(
            .fileURLs([one, two]), existingCount: 0, cap: 10,
            attachFiles: { attached.append($0) },
            attachImage: { images.append($0) },
            overflow: { overflow.append($0) }
        )

        // One call with the picker's shape of input: the URLs, in order.
        XCTAssertEqual(attached, [[one, two]])
        XCTAssertTrue(images.isEmpty)
        XCTAssertTrue(overflow.isEmpty)
    }

    func testFolderOverflowIsReportedOnceAndOnlyTheCapIsAttached() throws {
        let folder = try makeDirectory()
        for index in 1...4 { try touch("f\(index).txt", in: folder) }

        var attached: [[URL]] = []
        var overflow: [Int] = []
        MacAttachmentDropRouter.route(
            .fileURLs([folder]), existingCount: 1, cap: 3,
            attachFiles: { attached.append($0) },
            attachImage: { _ in },
            overflow: { overflow.append($0) }
        )

        XCTAssertEqual(attached.map { $0.map(\.lastPathComponent) }, [["f1.txt", "f2.txt"]])
        XCTAssertEqual(overflow, [2])
    }

    func testRawImagesGoThroughThePasteImagePathAndCountAgainstTheCap() {
        let images = (0..<3).map { _ in PastedImage(data: pngData(), typeIdentifier: UTType.png.identifier) }

        var attachedFiles = 0
        var pasted: [PastedImage] = []
        var overflow: [Int] = []
        MacAttachmentDropRouter.route(
            .images(images), existingCount: 0, cap: 2,
            attachFiles: { _ in attachedFiles += 1 },
            attachImage: { pasted.append($0) },
            overflow: { overflow.append($0) }
        )

        XCTAssertEqual(attachedFiles, 0)
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(overflow, [1])
    }

    func testEmptyFolderAttachesNothing() throws {
        let folder = try makeDirectory()
        var called = false
        MacAttachmentDropRouter.route(
            .fileURLs([folder]), existingCount: 0, cap: 10,
            attachFiles: { _ in called = true },
            attachImage: { _ in },
            overflow: { _ in }
        )
        XCTAssertFalse(called)
    }

    // MARK: Locked composer

    func testDropIsRefusedWhileTheComposerIsLocked() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])

        var received: [MacAttachmentDropPayload] = []
        let locked = sink(enabled: false) { received.append($0) }

        XCTAssertEqual(locked.operation(for: pb), [])
        XCTAssertFalse(locked.perform(pb))
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(locked.isTargeted)
    }

    func testDropIsAcceptedWhileTheComposerIsEnabled() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])

        var received: [MacAttachmentDropPayload] = []
        let open = sink(enabled: true) { received.append($0) }

        XCTAssertEqual(open.operation(for: pb), .copy)
        XCTAssertTrue(open.perform(pb))
        XCTAssertEqual(received, [.fileURLs([file])])
    }

    func testDropIsRefusedWithoutAComposerToReceiveIt() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])

        let bare = MacAttachmentDropSink()
        XCTAssertEqual(bare.operation(for: pb), [])
        XCTAssertFalse(bare.perform(pb))
    }

    func testNonAttachableDragIsDeferredEvenWhenEnabled() {
        let pb = board()
        pb.setString("text", forType: .string)
        let open = sink(enabled: true)
        XCTAssertEqual(open.operation(for: pb), [])
        XCTAssertFalse(open.perform(pb))
    }

    // MARK: Text view hands drags to the sink

    func testComposerTextViewUsesTheSinkForFileDrops() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])

        var received: [MacAttachmentDropPayload] = []
        let view = ComposerTextView()
        // The view holds its sink weakly; the pane owns it.
        let open = sink(enabled: true) { received.append($0) }
        let locked = sink(enabled: false) { received.append($0) }

        view.dropSink = open
        XCTAssertEqual(view.dragOperation(for: pb), .copy)

        view.dropSink = locked
        XCTAssertEqual(view.dragOperation(for: pb), [])
        XCTAssertTrue(received.isEmpty)
    }

    private final class StubDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .every }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        var draggingFormation: NSDraggingFormation { get { .default } set {} }
        var animatesToDestination: Bool { get { false } set {} }
        var numberOfValidItemsForDrop: Int { get { 1 } set {} }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    func testLockedComposerRefusesFileDragsInsteadOfFallingBackToTheTextView() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])
        let info = StubDraggingInfo(pb)

        let view = ComposerTextView()
        let locked = sink(enabled: false)
        view.dropSink = locked
        XCTAssertEqual(view.draggingEntered(info), [], "no-drop cursor, not NSTextView's own file handling")
        XCTAssertEqual(view.draggingUpdated(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertFalse(locked.isTargeted)
    }

    func testEnabledComposerShowsTheOverlayAndTracksTheDrag() throws {
        let dir = try makeDirectory()
        let file = try touch("a.txt", in: dir)
        let pb = board()
        pb.writeObjects([file as NSURL])
        let info = StubDraggingInfo(pb)

        var received: [MacAttachmentDropPayload] = []
        let open = sink(enabled: true) { received.append($0) }
        let view = ComposerTextView()
        view.dropSink = open

        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertTrue(open.isTargeted)
        // The pane's own target can report its exit after this view's entry;
        // the next update restores the overlay.
        open.setTargeted(false)
        XCTAssertEqual(view.draggingUpdated(info), .copy)
        XCTAssertTrue(open.isTargeted)
        view.draggingExited(info)
        XCTAssertFalse(open.isTargeted)

        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertFalse(open.isTargeted)
        XCTAssertEqual(received, [.fileURLs([file])])
    }

    // MARK: Hosted: a drop lands in the composer's draft like a picked file

    private final class SinkBox { var sink: MacAttachmentDropSink? }

    private struct SinkProbe: View {
        let box: SinkBox
        @Environment(\.macAttachmentDropSink) private var sink
        var body: some View {
            Color.clear.frame(width: 1, height: 1).onAppear { box.sink = sink }
        }
    }

    func testDroppedFilesStageIntoTheActiveChatsDraftOnly() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(boostWasOn) }

        let appState = AppStateRuntimeRegistry.shared.appState
        let previousSession = appState.activeSessionId
        let chatA = "drop-test-\(UUID().uuidString)"
        let chatB = "drop-test-\(UUID().uuidString)"
        appState.activeSessionId = chatA
        defer { appState.activeSessionId = previousSession }
        try XCTSkipUnless(appState.composerIsEnabled, "shared AppState composer is locked in this run")

        let dir = try makeDirectory()
        let note = try touch("dropped-note.txt", in: dir)
        let picture = dir.appendingPathComponent("dropped-pic.png")
        try pngData().write(to: picture)
        let pb = board()
        pb.writeObjects([note as NSURL, picture as NSURL])

        let box = SinkBox()
        let window = HostedTestSupport.host(
            VStack(spacing: 0) {
                SinkProbe(box: box)
                ComposerBar()
            }
            .macChatAttachmentDrop()
            .environmentObject(appState),
            size: NSSize(width: 720, height: 300)
        )
        defer { HostedTestSupport.tearDown(window) }
        AccessibilityTreeBoost.set(true)

        XCTAssertTrue(HostedTestSupport.waitUntil { box.sink?.receiver != nil }, "composer never registered as the drop receiver")
        let keyA = ComposerBar.composerDraftKey(for: chatA, profile: appState.activeProfile)
        let keyB = ComposerBar.composerDraftKey(for: chatB, profile: appState.activeProfile)
        defer {
            appState.composerDraftStore.removeDraft(for: keyA)
            appState.composerDraftStore.removeDraft(for: keyB)
        }

        XCTAssertTrue(box.sink?.perform(pb) == true)
        // Staging copies off the main actor, then appends: each attachment
        // shows up as a chip with a Remove button named after it.
        func chipShown(_ name: String) -> Bool {
            AccessibilityProbe.labels(in: window).contains { $0.contains(name) }
        }
        XCTAssertTrue(
            HostedTestSupport.waitUntil(timeout: 10) { chipShown("dropped-note.txt") && chipShown("dropped-pic.png") },
            "\(AccessibilityProbe.labels(in: window))"
        )

        // Leaving the chat saves its draft: the dropped files are in A, not B.
        appState.activeSessionId = chatB
        XCTAssertTrue(HostedTestSupport.waitUntil { !appState.composerDraftStore.draft(for: keyA).attachments.isEmpty })
        let staged = appState.composerDraftStore.draft(for: keyA).attachments
        defer {
            staged.forEach {
                if let url = URL(string: $0.uri), url.isFileURL { try? FileManager.default.removeItem(at: url) }
            }
        }
        XCTAssertEqual(staged.map(\.name), ["dropped-note.txt", "dropped-pic.png"])
        // An image FILE takes the picker's staging and stays an image.
        let image = try XCTUnwrap(staged.last)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(staged.first?.kind, .document)
        XCTAssertTrue(appState.composerDraftStore.draft(for: keyB).attachments.isEmpty)
    }
}
