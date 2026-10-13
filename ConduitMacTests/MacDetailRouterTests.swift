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
            XCTAssertEqual(MacDetailRouter<EmptyView>.tabAfterOpening(current: tab, openedSessionId: "s1"), .sessions)
        }
    }

    func testClearingSessionKeepsTab() {
        XCTAssertEqual(MacDetailRouter<EmptyView>.tabAfterOpening(current: .kanban, openedSessionId: nil), .kanban)
    }

    func testSidebarVisibilityMapping() {
        XCTAssertEqual(MacSidebarState.visibility(isVisible: true), .all)
        XCTAssertEqual(MacSidebarState.visibility(isVisible: false), .detailOnly)
        XCTAssertTrue(MacSidebarState.isVisible(.all))
        XCTAssertTrue(MacSidebarState.isVisible(.automatic))
        XCTAssertFalse(MacSidebarState.isVisible(.detailOnly))
    }
}
