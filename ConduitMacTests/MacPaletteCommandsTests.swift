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
}
