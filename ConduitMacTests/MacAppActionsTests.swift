import AppKit
import XCTest
@testable import ConduitMac

/// Settings (Cmd-,) and Switch Dashboard (Cmd-Shift-D) actions (D22). Windows
/// are bare NSWindows with the identifiers SwiftUI gives the real ones; the
/// notification centre is injected so nothing reaches the live app.
@MainActor
final class MacAppActionsTests: XCTestCase {
    final class PostCounter { var count = 0 }

    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []
    private var center: NotificationCenter!
    private var counter: PostCounter!
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        center = NotificationCenter()
        counter = PostCounter()
        let counter = counter!
        observer = center.addObserver(forName: .macOpenSettingsRequested, object: nil, queue: nil) { _ in
            counter.count += 1
        }
    }

    override func tearDown() async throws {
        if let observer { center.removeObserver(observer) }
        windows.forEach { $0.close() }
        windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func window(_ identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        if let identifier { w.identifier = NSUserInterfaceItemIdentifier(identifier) }
        windows.append(w)
        return w
    }

    private func primary() -> NSWindow { window("conduit-primary-AppWindow-1") }
    private func session() -> NSWindow { window("conduit-session-AppWindow-1") }

    private func attachSheet(to parent: NSWindow) -> NSWindow {
        let sheet = window(nil)
        parent.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { parent.attachedSheet != nil })
        return sheet
    }

    // MARK: window resolution

    func testChatWindowIsThePrimaryWindowItself() {
        let main = primary()
        XCTAssertTrue(MacAppActions.chatWindow(for: main, windows: [main]) === main)
    }

    func testSessionWindowResolvesToThePrimaryWindow() {
        let main = primary(), side = session()
        XCTAssertTrue(MacAppActions.chatWindow(for: side, windows: [side, main]) === main)
        XCTAssertNil(MacAppActions.chatWindow(for: side, windows: [side]), "no primary window open")
    }

    func testOtherWindowsResolveToNothing() {
        let main = primary()
        XCTAssertNil(MacAppActions.chatWindow(for: window("com_apple_SwiftUI_Settings_window"), windows: [main]))
        XCTAssertNil(MacAppActions.chatWindow(for: window(nil), windows: [main]))
        XCTAssertNil(MacAppActions.chatWindow(for: nil, windows: [main]))
        XCTAssertFalse(MacAppActions.isSessionWindow(main))
        XCTAssertTrue(MacAppActions.isSessionWindow(session()))
    }

    func testBothSessionWindowHelpersAgreeOnASwiftUIIdentifier() {
        let side = window("\(MacSessionWindows.sceneID)-AppWindow-1")
        XCTAssertTrue(MacSessionWindows.isSessionWindow(side))
        XCTAssertTrue(MacAppActions.isSessionWindow(side))
        let main = primary()
        XCTAssertFalse(MacSessionWindows.isSessionWindow(main))
        XCTAssertFalse(MacAppActions.isSessionWindow(main))
    }

    // MARK: Settings

    func testSettingsPostsOnceFromThePrimaryWindow() {
        let store = MacPaletteStore(defaults: suite.defaults)
        XCTAssertTrue(MacAppActions.openSettings(window: primary(), palette: store, center: center))
        XCTAssertEqual(counter.count, 1)
    }

    func testSettingsDoesNothingFromNonChatWindows() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary()
        for w in [window("com_apple_SwiftUI_Settings_window"), window(nil), nil] as [NSWindow?] {
            XCTAssertFalse(MacAppActions.openSettings(window: w, windows: [main], palette: store, center: center))
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsDoesNothingUnderASheetOrFromTheSheetItself() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.openSettings(window: main, palette: store, center: center), "sheet attached")
        XCTAssertFalse(MacAppActions.openSettings(window: sheet, windows: [main], palette: store, center: center), "the sheet is key")
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsFromASessionWindowBringsThePrimaryForwardAndPosts() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let main = primary(), side = session()
        XCTAssertFalse(main.isVisible)
        XCTAssertTrue(MacAppActions.openSettings(window: side, windows: [side, main], palette: store, center: center))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(main.isVisible, "the sheet appears in the primary window, so it must be on screen")
    }

    func testSettingsFromASessionWindowWithNoPrimaryWindowDoesNothing() {
        let store = MacPaletteStore(defaults: suite.defaults)
        let side = session()
        XCTAssertFalse(MacAppActions.openSettings(window: side, windows: [side], palette: store, center: center, openMainWindow: {}))
        XCTAssertEqual(counter.count, 0)
    }

    func testSettingsClosesAnOpenPaletteFirst() {
        let store = MacPaletteStore(defaults: suite.defaults)
        store.present()
        XCTAssertTrue(store.isPresented)
        XCTAssertTrue(MacAppActions.openSettings(window: primary(), palette: store, center: center))
        XCTAssertFalse(store.isPresented)
    }

    func testBlockedSettingsLeavesAnOpenPaletteAlone() {
        let store = MacPaletteStore(defaults: suite.defaults)
        store.present()
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.openSettings(window: main, palette: store, center: center))
        XCTAssertTrue(store.isPresented)
    }

    // MARK: Switch Dashboard

    func testSwitchDashboardPresentsFromThePrimaryWindow() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented, "a second press keeps one presentation")
    }

    func testSwitchDashboardDoesNothingFromNonChatWindows() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary()
        for w in [window("com_apple_SwiftUI_Settings_window"), window(nil), nil] as [NSWindow?] {
            XCTAssertFalse(MacAppActions.switchDashboard(window: w, windows: [main], palette: palette, switcher: switcher))
        }
        XCTAssertFalse(switcher.isPresented)
    }

    func testSwitchDashboardDoesNothingUnderASheetOrFromTheSheetItself() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary()
        main.orderFront(nil)
        let sheet = attachSheet(to: main)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(MacAppActions.switchDashboard(window: main, palette: palette, switcher: switcher))
        XCTAssertFalse(MacAppActions.switchDashboard(window: sheet, windows: [main], palette: palette, switcher: switcher))
        XCTAssertFalse(switcher.isPresented)
    }

    func testSwitchDashboardFromASessionWindowBringsThePrimaryForward() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        let switcher = MacDashboardSwitcherStore()
        let main = primary(), side = session()
        XCTAssertTrue(MacAppActions.switchDashboard(window: side, windows: [side, main], palette: palette, switcher: switcher))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertTrue(main.isVisible)
        let lone = MacDashboardSwitcherStore()
        XCTAssertFalse(MacAppActions.switchDashboard(window: side, windows: [side], palette: palette, switcher: lone, openMainWindow: {}))
        XCTAssertFalse(lone.isPresented, "no primary window: no orphan sheet")
    }

    func testSwitchDashboardClosesAnOpenPaletteFirst() {
        let palette = MacPaletteStore(defaults: suite.defaults)
        palette.present()
        let switcher = MacDashboardSwitcherStore()
        XCTAssertTrue(MacAppActions.switchDashboard(window: primary(), palette: palette, switcher: switcher))
        XCTAssertFalse(palette.isPresented)
        XCTAssertTrue(switcher.isPresented)
    }
}
