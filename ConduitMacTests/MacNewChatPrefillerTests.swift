import XCTest
@testable import ConduitMac

@MainActor
final class MacNewChatPrefillerTests: XCTestCase {
    private var active: String? = "old"
    private var prefilled: [String] = []

    private func prefiller(creating newID: String?) -> MacNewChatPrefiller {
        MacNewChatPrefiller(
            activeSessionId: { [unowned self] in self.active },
            createNewSession: { [unowned self] in if let newID { self.active = newID } },
            prefill: { [unowned self] in self.prefilled.append($0) }
        )
    }

    func testPrefillsAfterTheNewSessionIsActive() async {
        let ok = await prefiller(creating: "new").run("hello")
        XCTAssertTrue(ok)
        XCTAssertEqual(prefilled, ["hello"])
        XCTAssertEqual(active, "new")
    }

    func testRefusedCreateNeverPrefillsTheActiveChat() async {
        let ok = await prefiller(creating: nil).run("hello")
        XCTAssertFalse(ok)
        XCTAssertTrue(prefilled.isEmpty, "the open chat's draft must not be overwritten")
    }

    func testChatOpenedMeanwhileWithADraftIsNeverOverwritten() async {
        // The create awaits the gateway; the user opened another chat that has a draft.
        let p = MacNewChatPrefiller(
            activeSessionId: { [unowned self] in self.active },
            createNewSession: { [unowned self] in self.active = "other-with-draft" },
            prefill: { [unowned self] in self.prefilled.append($0) },
            activeDraftIsEmpty: { false }
        )
        let ok = await p.run("hello")
        XCTAssertFalse(ok)
        XCTAssertTrue(prefilled.isEmpty)
    }

    func testParkedRequestWaitsForConnectedSettledAndNotSwitching() {
        XCTAssertTrue(AppState.macCanApplyParkedRequest(isConnected: true, isConnecting: false, isProfileSwitching: false))
        XCTAssertFalse(AppState.macCanApplyParkedRequest(isConnected: false, isConnecting: false, isProfileSwitching: false))
        XCTAssertFalse(AppState.macCanApplyParkedRequest(isConnected: true, isConnecting: true, isProfileSwitching: false))
        XCTAssertFalse(AppState.macCanApplyParkedRequest(isConnected: true, isConnecting: false, isProfileSwitching: true),
                       "createNewSession refuses during a switch; the request must wait, not be consumed")
    }

    func testPrefillSeesTheNewSessionNotTheOldOne() async {
        var seen: String?
        let p = MacNewChatPrefiller(
            activeSessionId: { [unowned self] in self.active },
            createNewSession: { [unowned self] in self.active = "new" },
            prefill: { [unowned self] _ in seen = self.active }
        )
        _ = await p.run("x")
        XCTAssertEqual(seen, "new")
    }
}
