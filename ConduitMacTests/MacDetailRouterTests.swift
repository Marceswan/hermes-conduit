import SwiftUI
import XCTest
@testable import ConduitMac

final class MacDetailRouterTests: XCTestCase {
    func testTabToDestinationMappings() {
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .sessions), .chat)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .bots), .bots)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .cron), .cron)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .kanban), .kanban)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .home), .home)
    }

    func testOpeningSessionReturnsToSessions() {
        for tab in SidebarTab.allCases {
            XCTAssertEqual(MacDetailRouter<EmptyView>.tabAfterOpening(current: tab, openedID: "s1"), .sessions)
        }
    }

    func testClearingSessionKeepsTab() {
        XCTAssertEqual(MacDetailRouter<EmptyView>.tabAfterOpening(current: .kanban, openedID: nil), .kanban)
    }

    func testSidebarVisibilityMapping() {
        XCTAssertEqual(MacSidebarState.visibility(isVisible: true), .all)
        XCTAssertEqual(MacSidebarState.visibility(isVisible: false), .detailOnly)
        XCTAssertTrue(MacSidebarState.isVisible(.all))
        XCTAssertTrue(MacSidebarState.isVisible(.automatic))
        XCTAssertFalse(MacSidebarState.isVisible(.detailOnly))
    }
}

@MainActor
final class MacDetailRouterMountTests: XCTestCase {
    private final class Counts: ObservableObject {
        var appears = 0
        var disappears = 0
    }

    private struct Probe: View {
        let counts: Counts
        var body: some View {
            Color.clear.onAppear { counts.appears += 1 }.onDisappear { counts.disappears += 1 }
        }
    }

    func testChatStaysMountedAcrossChatKanbanChat() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let counts = Counts()
        let window = HostedTestSupport.host(
            MacDetailRouter(defaults: suite.defaults, notificationCenter: NotificationCenter(), chat: { Probe(counts: counts) })
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .frame(width: 600, height: 400),
            size: NSSize(width: 600, height: 400))
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { counts.appears == 1 })
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        HostedTestSupport.settle(0.3)
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        HostedTestSupport.settle(0.3)
        XCTAssertEqual(counts.disappears, 0, "chat must not be torn down by a tab switch")
        XCTAssertEqual(counts.appears, 1)
    }
}

@MainActor
final class ToggleSidebarMenuTests: XCTestCase {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    func testExactlyOneToggleSidebarItemOnCmdCtrlS() throws {
        let main = try XCTUnwrap(NSApp.mainMenu, "SwiftUI has not built the main menu")
        let matches = allItems(main).filter {
            $0.keyEquivalent == "s"
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .control]
        }
        XCTAssertEqual(matches.count, 1, "found: \(matches.map(\.title))")
        XCTAssertTrue(matches.first?.title.contains("Sidebar") ?? false)
    }
}
