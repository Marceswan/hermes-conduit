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

    /// A signature pin, not a behavior test: `AppState` passes `linkID` to `turnStarted` (#1039), so the
    /// stub must accept the label. The call can fail only as a compile error. The stub keeps no state, so
    /// there is nothing to assert after it.
    func testTurnStartedAcceptsALinkIDAsUpstreamsSignatureDoes() {
        LiveTurnActivities.shared.turnStarted(
            sessionIDs: ["s1"],
            primaryID: "s1",
            linkID: "s1",
            title: "Chat",
            profile: "default"
        )
    }
}
