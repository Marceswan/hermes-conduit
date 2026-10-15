import XCTest
@testable import ConduitMac

@MainActor
final class MacIntentInboxTests: XCTestCase {
    func testLastWriteWinsAndTakeIsOneShot() {
        let inbox = MacIntentInbox()
        inbox.enqueue(.newChat(profile: nil, message: "a"))
        inbox.enqueue(.openSession(id: "s", profile: "p"))
        XCTAssertEqual(inbox.take(), .openSession(id: "s", profile: "p"))
        XCTAssertNil(inbox.take())
        XCTAssertFalse(inbox.hasPending)
    }

    func testEnqueueBumpsRevision() {
        let inbox = MacIntentInbox()
        let before = inbox.revision
        inbox.enqueue(.newChat(profile: nil, message: nil))
        XCTAssertGreaterThan(inbox.revision, before)
    }

    func testDataSourceIsEmptyAndUnavailableBeforeBinding() {
        let source = MacIntentDataSource()
        XCTAssertTrue(source.sessions.isEmpty)
        XCTAssertFalse(source.isAvailable)
    }
}
