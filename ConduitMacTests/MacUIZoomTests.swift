import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// View > Zoom (D27): the level steps, the stored-value guard, the fit guard,
/// plain Cmd-=, and the layout that scales a column and its minimum.
@MainActor
final class MacUIZoomTests: XCTestCase {
    func testZoomInAndOutWalkEveryLevelAndStopAtTheEnds() {
        var level = MacUIZoom.levels[0]
        var seen = [level]
        while let next = MacUIZoom.target(of: .zoomIn, from: level) { seen.append(next); level = next }
        XCTAssertEqual(seen, MacUIZoom.levels)
        XCTAssertNil(MacUIZoom.target(of: .zoomIn, from: 2))
        XCTAssertEqual(MacUIZoom.target(of: .zoomOut, from: 1), 0.85)
        XCTAssertNil(MacUIZoom.target(of: .zoomOut, from: 0.75))
        XCTAssertEqual(MacUIZoom.target(of: .actualSize, from: 1.5), 1)
        XCTAssertNil(MacUIZoom.target(of: .actualSize, from: 1))
    }

    func testAStoredValueOffTheStepsOrDamagedIsClamped() {
        XCTAssertEqual(MacUIZoom.scale(.nan), 1)
        XCTAssertEqual(MacUIZoom.scale(0), 1)
        XCTAssertEqual(MacUIZoom.scale(-2), 1)
        XCTAssertEqual(MacUIZoom.scale(0.1), 0.75)
        XCTAssertEqual(MacUIZoom.scale(9), 2)
        XCTAssertEqual(MacUIZoom.scale(1.3), 1.3)
        XCTAssertEqual(MacUIZoom.target(of: .zoomIn, from: 1.3), 1.5)
        XCTAssertEqual(MacUIZoom.target(of: .zoomOut, from: 1.3), 1.25)
    }

    func testPerformWritesTheLevelAndBeepsOnlyAtTheEnds() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        var beeps = 0
        func run(_ step: MacUIZoom.Step) -> Bool {
            MacUIZoom.perform(step, defaults: suite.defaults, fits: { _ in true }, refuse: { beeps += 1 })
        }
        func stored() -> Double? { suite.defaults.object(forKey: MacUIZoom.defaultsKey) as? Double }

        XCTAssertTrue(run(.zoomIn))
        XCTAssertEqual(stored(), 1.15)
        XCTAssertTrue(run(.zoomOut))
        XCTAssertTrue(run(.zoomOut))
        XCTAssertEqual(stored(), 0.85)
        XCTAssertTrue(run(.actualSize))
        XCTAssertEqual(stored(), 1)
        XCTAssertFalse(run(.actualSize), "Actual Size at 100% does nothing")
        XCTAssertEqual(beeps, 0, "and does not beep")

        suite.defaults.set(2.0, forKey: MacUIZoom.defaultsKey)
        XCTAssertFalse(run(.zoomIn))
        suite.defaults.set(0.75, forKey: MacUIZoom.defaultsKey)
        XCTAssertFalse(run(.zoomOut))
        XCTAssertEqual(stored(), 0.75)
        XCTAssertEqual(beeps, 2)
    }

    func testZoomInStopsWhenTheWindowWouldNotFitButZoomOutNeverDoes() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        var beeps = 0
        var asked: [Double] = []
        suite.defaults.set(1.25, forKey: MacUIZoom.defaultsKey)
        let tooBig: (Double) -> Bool = { asked.append($0); return false }

        XCTAssertFalse(MacUIZoom.perform(.zoomIn, defaults: suite.defaults, fits: tooBig, refuse: { beeps += 1 }))
        XCTAssertEqual(asked, [1.5], "the guard judges the next level")
        XCTAssertEqual(suite.defaults.double(forKey: MacUIZoom.defaultsKey), 1.25)
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(MacUIZoom.perform(.zoomOut, defaults: suite.defaults, fits: tooBig, refuse: { beeps += 1 }))
        XCTAssertEqual(asked.count, 1)
    }

    func testFitAddsTheChromeToTheScaledMinimum() {
        let minimum = CGSize(width: 820, height: 560)
        // A 14-inch MacBook Pro at its default resolution, with the menu bar and Dock.
        let laptop = CGSize(width: 1512, height: 944)
        XCTAssertTrue(MacUIZoom.fits(1.5, minimum: minimum, chrome: 52, in: laptop))
        XCTAssertFalse(MacUIZoom.fits(1.75, minimum: minimum, chrome: 52, in: laptop), "980 + 52 pt is taller than 944")
        XCTAssertFalse(MacUIZoom.fits(1, minimum: minimum, chrome: 0, in: CGSize(width: 800, height: 2000)))
        XCTAssertTrue(MacUIZoom.fits(2, minimum: minimum, chrome: 52, in: CGSize(width: 2560, height: 1415)))
    }

    func testTheMainWindowMinimumIsTheSplitLayouts() {
        XCTAssertEqual(MacUIZoom.windowMinimum, CGSize(width: MacSidebarState.windowMinWidth, height: MacSidebarState.windowMinHeight))
    }

    func testFitWithNoMainWindowAllowsEveryLevel() {
        XCTAssertTrue(MacUIZoom.fitsMainWindow(2, windows: []))
    }

    // MARK: - Cmd-=

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 24) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    func testOnlyPlainCmdEqualsIsTakenAsZoomIn() {
        XCTAssertTrue(MacUIZoom.isPlainZoomInKey(key("=", .command)))
        XCTAssertTrue(MacUIZoom.isPlainZoomInKey(key("=", [.command, .capsLock])), "Caps Lock does not change the shortcut")
        XCTAssertFalse(MacUIZoom.isPlainZoomInKey(key("+", [.command, .shift])), "Cmd-+ is the menu item's own key")
        XCTAssertFalse(MacUIZoom.isPlainZoomInKey(key("=", [.command, .option])))
        XCTAssertFalse(MacUIZoom.isPlainZoomInKey(key("=", [.command, .control])))
        XCTAssertFalse(MacUIZoom.isPlainZoomInKey(key("=", [])), "a typed = stays text")
        XCTAssertFalse(MacUIZoom.isPlainZoomInKey(key("-", .command, keyCode: 27)))
    }

    // MARK: - Layout

    /// Records the size the zoomed child was given.
    private final class SizeBox { var size: CGSize = .zero }

    func testTheChildLaysOutAtTheContainerSizeDividedByTheZoom() {
        let box = SizeBox()
        let view = GeometryReader { proxy in
            Color.clear.onAppear { box.size = proxy.size }
        }
        .macUIZoom(1.5)
        let window = HostedTestSupport.host(view.frame(width: 300, height: 240), size: NSSize(width: 300, height: 240))
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { box.size != .zero })
        XCTAssertEqual(box.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(box.size.height, 160, accuracy: 0.5)
    }

    func testAMinimumSizeInsideGrowsWithTheZoom() {
        let host = NSHostingView(rootView: Color.clear.frame(minWidth: 100, minHeight: 50).macUIZoom(1.5))
        let fitting = host.fittingSize
        XCTAssertEqual(fitting.width, 150, accuracy: 0.5)
        XCTAssertEqual(fitting.height, 75, accuracy: 0.5)
    }

    // MARK: - Following the latest message

    /// A transcript like ChatView's: a SwiftUI ScrollView whose NSScrollView the
    /// locator hands to the engine, zoomed by the level in `defaults`.
    private struct ZoomedTranscript: View {
        let engine: ChatScrollEngine
        @AppStorage private var level: Double

        init(engine: ChatScrollEngine, defaults: UserDefaults) {
            self.engine = engine
            _level = AppStorage(wrappedValue: MacUIZoom.actualSize, MacUIZoom.defaultsKey, store: defaults)
        }

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<120, id: \.self) { Text("message \($0)").frame(maxWidth: .infinity, minHeight: 28) }
                }
                .background(ChatScrollSurfaceLocator(engine: engine))
            }
            .macUIZoom(MacUIZoom.scale(level))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private static func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let content = scroll.documentView?.frame.height ?? 0
        let visible = scroll.contentView.bounds
        return content + scroll.contentInsets.bottom - visible.maxY
    }

    /// A chat that follows its latest message still shows it after a zoom
    /// change, in and out, and still follows it.
    func testAChatAtItsLatestMessageStaysThereWhenTheZoomChanges() throws {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let engine = ChatScrollEngine()
        let window = HostedTestSupport.host(ZoomedTranscript(engine: engine, defaults: suite.defaults)
            .frame(width: 400, height: 500), size: NSSize(width: 400, height: 500))
        defer { HostedTestSupport.tearDown(window) }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(HostedTestSupport.waitUntil { Self.scrollView(in: content) != nil })
        let scroll = try XCTUnwrap(Self.scrollView(in: content))
        HostedTestSupport.settle(0.2)
        engine.explicitLatestRequested(animated: false)
        XCTAssertTrue(HostedTestSupport.waitUntil { abs(Self.distanceFromBottom(scroll)) < 1 }, "at the end first")
        XCTAssertTrue(engine.isFollowingLatest)

        for (step, level) in [(MacUIZoom.Step.zoomIn, 1.15), (.zoomIn, 1.25), (.zoomIn, 1.5), (.actualSize, 1), (.zoomOut, 0.85)] {
            XCTAssertTrue(MacUIZoom.perform(step, defaults: suite.defaults, fits: { _ in true }, refuse: {}))
            XCTAssertEqual(suite.defaults.double(forKey: MacUIZoom.defaultsKey), level)
            HostedTestSupport.settle(NSScrollViewChatSurface.zoomSettleDelay + 0.2)
            XCTAssertEqual(Self.distanceFromBottom(scroll), 0, accuracy: 1, "at \(level) the latest message is still in view")
            XCTAssertTrue(engine.isFollowingLatest, "at \(level) the chat still follows")
        }
    }

    /// A reader scrolled up into older messages is not moved to the end by a zoom change.
    func testAChatScrolledUpIsNotMovedToTheEndByAZoomChange() throws {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let engine = ChatScrollEngine()
        let window = HostedTestSupport.host(ZoomedTranscript(engine: engine, defaults: suite.defaults)
            .frame(width: 400, height: 500), size: NSSize(width: 400, height: 500))
        defer { HostedTestSupport.tearDown(window) }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(HostedTestSupport.waitUntil { Self.scrollView(in: content) != nil })
        let scroll = try XCTUnwrap(Self.scrollView(in: content))
        HostedTestSupport.settle(0.2)
        engine.explicitLatestRequested(animated: false)
        XCTAssertTrue(HostedTestSupport.waitUntil { abs(Self.distanceFromBottom(scroll)) < 1 })
        // A scroll-bar click or wheel notch to older messages (no live scroll).
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(HostedTestSupport.waitUntil { !engine.isFollowingLatest }, "the reader left the end")

        XCTAssertTrue(MacUIZoom.perform(.zoomIn, defaults: suite.defaults, fits: { _ in true }, refuse: {}))
        HostedTestSupport.settle(NSScrollViewChatSurface.zoomSettleDelay + 0.2)
        XCTAssertFalse(engine.isFollowingLatest)
        XCTAssertGreaterThan(Self.distanceFromBottom(scroll), 1_000, "still among the older messages")
    }

    /// The window minimum follows the zoom: a hosted `MacSplitLayout` reading an
    /// injected suite at 150% does not let its window shrink below 150% of the 100% minimum.
    func testTheSplitLayoutWindowMinimumFollowsTheZoom() throws {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(1.5, forKey: MacUIZoom.defaultsKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MacSplitLayout(
            defaults: suite.defaults, sidebar: { List { Text("sidebar row") } }, chat: { Text("chat") })
            .environmentObject(AppStateRuntimeRegistry.shared.appState))
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.orderFront(nil)
        defer { HostedTestSupport.tearDown(window) }

        let zoomed = CGSize(width: MacSidebarState.windowMinWidth * 1.5, height: MacSidebarState.windowMinHeight * 1.5)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.contentMinSize.width >= zoomed.width - 0.5 },
                      "min \(window.contentMinSize)")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, zoomed.height - 0.5)

        suite.defaults.set(1.0, forKey: MacUIZoom.defaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.contentMinSize.width < zoomed.width - 0.5 },
                      "Actual Size gives the 100% minimum back: \(window.contentMinSize)")
    }
}
