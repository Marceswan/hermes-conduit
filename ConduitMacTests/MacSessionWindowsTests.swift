import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowsTests: XCTestCase {
    func testSessionWindowIdentifierIsNotMainChatWindow() {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        XCTAssertTrue(MacSessionWindows.isSessionWindow(window))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window), "Cmd-W closes the window, not a tab")
    }

    func testOpenRequestsTokenAndCallsOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        var opened: [MacSessionWindowToken] = []
        XCTAssertTrue(MacSessionWindows.open("s1", appState: appState, registry: registry) { opened.append($0) })
        XCTAssertEqual(opened.map(\.sessionID), ["s1"])
        XCTAssertEqual(opened.first?.profile, appState.activeProfile)
    }

    func testOpenAtCapDoesNotCallOpenWindow() {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        for id in ["a", "b", "c", "d"] { _ = MacSessionWindows.open(id, appState: appState, registry: registry) { _ in } }
        var opened = 0
        XCTAssertFalse(MacSessionWindows.open("e", appState: appState, registry: registry) { _ in opened += 1 })
        XCTAssertEqual(opened, 0)
    }

    func testFocusComposerFromSessionWindowKeepsMainPane() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier("conduit-session-AppWindow-1")
        let center = NotificationCenter()
        var posted: [Any?] = []
        let observer = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { posted.append($0.object) }
        MacKeyboardActions.focusComposer(window: window, defaults: suite.defaults, center: center)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
        XCTAssertEqual(posted.count, 1)
        center.removeObserver(observer)
    }

    // MARK: A requested window that never appears

    func testARequestThatNeverAppearsIsReleasedAfterTheGracePeriod() async throws {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(MacSessionWindows.open(id, appState: appState, registry: registry, graceDelay: .milliseconds(30)) { _ in })
        }
        XCTAssertTrue(registry.isFull)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(registry.isFull, "an openWindow that produced no window must not hold its slot until relaunch")
    }

    func testAWindowThatAppearedIsNotReleasedByTheGracePeriod() async throws {
        let registry = MacSessionWindowRegistry()
        let appState = AppStateRuntimeRegistry.shared.appState
        var token: MacSessionWindowToken?
        XCTAssertTrue(MacSessionWindows.open("a", appState: appState, registry: registry, graceDelay: .milliseconds(30)) { token = $0 })
        let opened = try XCTUnwrap(token)
        XCTAssertTrue(registry.appeared(opened))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(registry.open.contains(opened))
        registry.disappeared(opened)
        XCTAssertTrue(registry.open.isEmpty)
    }

    func testReleaseOnlyForgetsAnUnappearedRequest() {
        let registry = MacSessionWindowRegistry()
        let waiting = MacSessionWindowToken(dashboardID: nil, profile: "p", sessionID: "w")
        let shown = MacSessionWindowToken(dashboardID: nil, profile: "p", sessionID: "s")
        XCTAssertTrue(registry.request(waiting))
        XCTAssertTrue(registry.request(shown))
        XCTAssertTrue(registry.appeared(shown))
        registry.releaseIfUnappeared(waiting)
        registry.releaseIfUnappeared(shown)
        XCTAssertFalse(registry.appeared(waiting), "released: a late window is treated as restored")
        XCTAssertTrue(registry.open.contains(shown))
    }
}
