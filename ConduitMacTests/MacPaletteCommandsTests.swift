import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteCommandsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func mainWindow() -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-1")
        windows.append(w)
        return w
    }

    func testComposerFocusIsRestoredAndTheDraftIsUntouched() {
        let window = mainWindow()
        let composer = ComposerTextView(frame: .init(x: 0, y: 0, width: 300, height: 80))
        composer.string = "half-written draft"
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)
        XCTAssertTrue(window.firstResponder === composer)

        let store = MacPaletteStore(defaults: suite.defaults)
        var focusRequests: [NSWindow] = []
        let observer = NotificationCenter.default.addObserver(forName: .macFocusComposerRequested, object: nil, queue: .main) {
            if let w = $0.object as? NSWindow { focusRequests.append(w) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertTrue(store.isPresented)
        XCTAssertTrue(focusRequests.isEmpty, "opening does not move focus")
        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(composer.string, "half-written draft")
        XCTAssertTrue(HostedTestSupport.waitUntil { focusRequests.count == 1 }, "closing asks the composer of this window to take focus back")
        XCTAssertTrue(focusRequests.first === window)
    }

    func testFocusIsNotRequestedWhenTheComposerDidNotHaveIt() {
        let window = mainWindow()
        let store = MacPaletteStore(defaults: suite.defaults)
        var count = 0
        let observer = NotificationCenter.default.addObserver(forName: .macFocusComposerRequested, object: nil, queue: .main) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        MacPaletteActions.toggle(store: store, window: window)
        MacPaletteActions.toggle(store: store, window: window)
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(count, 0)
    }

    func testCmdKTogglesRepeatedlyFromAnyPaneState() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let window = mainWindow()
        for _ in 0..<3 { MacPaletteActions.toggle(store: store, window: window) }
        XCTAssertTrue(store.isPresented)
    }

    func testFocusReturnsToAnotherAppKitResponderThatHeldIt() throws {
        let window = mainWindow()
        let sidebarField = NSTextField(frame: .init(x: 0, y: 0, width: 150, height: 22))
        let paletteField = NSTextField(frame: .init(x: 0, y: 40, width: 150, height: 22))
        window.contentView?.addSubview(sidebarField)
        window.contentView?.addSubview(paletteField)
        XCTAssertTrue(window.makeFirstResponder(sidebarField))

        let store = MacPaletteStore(defaults: suite.defaults)
        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertTrue(store.isPresented)
        XCTAssertTrue(window.makeFirstResponder(paletteField), "the palette's own field takes focus")
        MacPaletteActions.toggle(store: store, window: window)
        XCTAssertFalse(store.isPresented)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === sidebarField, "closing gives the field that held focus its focus back")
    }

    func testRestoreIsSkippedWhenTheResponderLeftTheWindow() {
        let window = mainWindow()
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 150, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let restore = MacPaletteActions.focusRestorer(in: window)
        field.removeFromSuperview()
        window.makeFirstResponder(nil)
        restore?()
        XCTAssertFalse(window.firstResponder is NSTextView, "a removed view is not made first responder")
    }

    func testTheStoreDoesNotRetainTheWindowThroughItsFocusRestorer() {
        weak var weakWindow: NSWindow?
        let store = MacPaletteStore(defaults: suite.defaults)
        autoreleasepool {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("conduit-primary-AppWindow-9")
            let composer = ComposerTextView(frame: .init(x: 0, y: 0, width: 100, height: 40))
            window.contentView?.addSubview(composer)
            window.makeFirstResponder(composer)
            weakWindow = window
            MacPaletteActions.toggle(store: store, window: window)
            XCTAssertTrue(store.isPresented)
            window.close()
        }
        XCTAssertNil(weakWindow, "a palette left open must not keep a closed window alive")
        store.dismiss()
    }
}
