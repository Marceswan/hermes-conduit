import SwiftUI
import XCTest
@testable import ConduitMac

final class MacChatRouteTests: XCTestCase {
    func testChatActiveOnlyForSessionsTab() {
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: SidebarTab.sessions.rawValue))
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: nil))
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: "Capabilities"), "removed raw values migrate to Sessions")
        for tab in [SidebarTab.bots, .cron, .kanban] {
            XCTAssertFalse(MacChatRoute.isChatActive(tabRaw: tab.rawValue))
        }
    }

    func testHiddenChatTitleIsPaneName() {
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.sessions.rawValue), "")
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.kanban.rawValue), SidebarTab.kanban.displayName)
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.bots.rawValue), SidebarTab.bots.displayName)
    }

    func testSessionOpenRequestReturnsEveryTabToSessions() {
        for tab in SidebarTab.allCases {
            XCTAssertEqual(MacDetailRouter<EmptyView>.tabAfterOpening(current: tab, openedID: "requested"), .sessions)
        }
    }

    func testColumnMetricsFitWindowMinimum() {
        XCTAssertLessThanOrEqual(
            MacSidebarState.sidebarMaxWidth + MacSidebarState.detailMinWidth,
            MacSidebarState.windowMinWidth,
            "detail pane would clip at the widest sidebar"
        )
        XCTAssertLessThanOrEqual(MacSidebarState.sidebarMinWidth, MacSidebarState.sidebarIdealWidth)
        XCTAssertLessThanOrEqual(MacSidebarState.sidebarIdealWidth, MacSidebarState.sidebarMaxWidth)
    }
}

@MainActor
final class MacHiddenChatFocusTests: XCTestCase {
    private func makeWindow(with views: [NSView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        for (i, view) in views.enumerated() {
            view.frame = NSRect(x: 10, y: 10 + i * 60, width: 200, height: 40)
            content.addSubview(view)
        }
        window.contentView = content
        return window
    }

    func testResignsFocusedComposer() {
        let composer = ComposerTextView()
        let window = makeWindow(with: [composer])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertTrue(MacChatRoute.resignComposerFocus(in: window))
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testLeavesOtherResponderAlone() {
        let field = NSTextField(frame: .zero)
        let window = makeWindow(with: [field])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(MacChatRoute.resignComposerFocus(in: window))
        XCTAssertFalse(window.firstResponder is ComposerTextView)
        XCTAssertFalse(MacChatRoute.resignComposerFocus(in: nil))
    }
}

@MainActor
final class MacSessionOpenSignalTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testSessionOpenRequestLeavesCronForChatOnlyWhenPosted() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.cron.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let host = NSHostingView(rootView:
            MacDetailRouter(chat: { Color.clear })
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        spin(0.3)
        // Sidebar chrome (filter chips, New Chat, search) posts nothing: the pane stays.
        XCTAssertEqual(defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.cron.rawValue)
        NotificationCenter.default.post(name: .macSessionOpenRequested, object: nil)
        spin(0.3)
        XCTAssertEqual(defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.sessions.rawValue)
    }
}
