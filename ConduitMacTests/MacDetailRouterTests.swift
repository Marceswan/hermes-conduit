import SwiftUI
import XCTest
@testable import ConduitMac

final class MacDetailRouterTests: XCTestCase {
    func testTabToDestinationMappings() {
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .sessions), .chat)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .bots), .bots)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .cron), .cron)
        XCTAssertEqual(MacDetailRouter<EmptyView>.destination(for: .kanban), .kanban)
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

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testChatStaysMountedAcrossChatKanbanChat() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let counts = Counts()
        let host = NSHostingView(rootView:
            MacDetailRouter(chat: { Probe(counts: counts) })
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        spin(0.3)
        XCTAssertEqual(counts.appears, 1)
        defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        spin(0.3)
        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        spin(0.3)
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
