import XCTest
@testable import ConduitMac

/// `LiveTurnActivities` is a no-op twin on Mac (ActivityKit is unavailable).
/// `AppState` asks it which chats stand behind a Live Activity card when a
/// link opens (#1039, #1057); with no card on Mac the answer must be empty,
/// so a link never resolves to a phantom chat.
@MainActor
final class LiveTurnActivitiesStubTests: XCTestCase {
    func testALinkNamesNoOtherChatBecauseNoCardExists() {
        let ids = LiveTurnActivities.sessionIDs(linkedTo: "s1", profile: "default", dashboardID: nil)
        XCTAssertEqual(ids, [])
    }

    func testStartingATurnWithALinkIDDoesNothing() {
        LiveTurnActivities.shared.turnStarted(
            sessionIDs: ["s1"],
            primaryID: "s1",
            linkID: "s1",
            title: "Chat",
            profile: "default"
        )
        XCTAssertFalse(LiveTurnActivities.shared.reconcile(liveSessionIDs: [], profile: "default", dashboardID: nil))
    }
}
