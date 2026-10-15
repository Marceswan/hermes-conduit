import UserNotifications
import XCTest
@testable import ConduitMac

final class MacNotificationContentTests: XCTestCase {
    private let session = makeSession()

    func testDoneRequest() {
        let r = MacNotificationContent.done(session: session, turnId: "t1", preview: "All 14 files migrated.", sound: true)
        XCTAssertEqual(r.identifier, "conduit.done.key-1")
        XCTAssertEqual(r.content.title, "Refactor billing")
        XCTAssertEqual(r.content.body, "All 14 files migrated.")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_DONE")
        XCTAssertEqual(r.content.threadIdentifier, "session-key-1")
        XCTAssertEqual(r.content.interruptionLevel, .active)
        XCTAssertNotNil(r.content.sound)
        XCTAssertNil(r.trigger)
    }

    func testDoneWithoutPreviewSaysFinishedAndSoundCanBeOff() {
        let r = MacNotificationContent.done(session: session, turnId: "t1", preview: "  \n ", sound: false)
        XCTAssertEqual(r.content.body, "Finished")
        XCTAssertNil(r.content.sound)
    }

    func testPreviewIsCollapsedAndTruncatedTo140() {
        let long = String(repeating: "word ", count: 80)
        let body = MacNotificationContent.done(session: session, turnId: "t", preview: long, sound: false).content.body
        XCTAssertLessThanOrEqual(body.count, 140)
        XCTAssertTrue(body.hasSuffix("\u{2026}"))
        XCTAssertEqual(MacNotificationContent.truncated("a\n\nb", limit: 140), "a b")
    }

    func testFailedRequestIsOpenOnly() {
        let r = MacNotificationContent.failed(session: session, turnId: "t1", sound: true)
        XCTAssertEqual(r.content.body, "Stopped with an error")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_OPEN")
        XCTAssertEqual(r.identifier, "conduit.done.key-1")
    }

    func testSummaryRequest() {
        let r = MacNotificationContent.doneSummary(count: 5, sound: true)
        XCTAssertEqual(r.identifier, "conduit.done.summary")
        XCTAssertTrue(r.content.title.contains("5"))
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testApprovalRequestCarriesCommandAsSubtitleAndPicksCategoryFromMapping() {
        let both = MacApprovalChoiceMapper.Mapping(approve: "once", deny: "deny")
        let r = MacNotificationContent.approval(session: session, requestId: "r9", description: "Run a shell command", command: "rm -rf build", mapping: both, sound: true)
        XCTAssertEqual(r.identifier, "conduit.approval.r9")
        XCTAssertEqual(r.content.subtitle, "rm -rf build")
        XCTAssertEqual(r.content.body, "Run a shell command")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL")
        let denyOnly = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: "deny"), sound: true)
        XCTAssertEqual(denyOnly.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        let none = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: nil), sound: true)
        XCTAssertEqual(none.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testApprovalWithoutDescriptionUsesTheCommandAsBody() {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "", command: "ls", mapping: .init(approve: "once", deny: "deny"), sound: false)
        XCTAssertEqual(r.content.body, "ls")
        XCTAssertEqual(r.content.subtitle, "")
    }

    func testLongCommandSubtitleIsTruncated() {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: String(repeating: "x", count: 300), mapping: .init(approve: "once", deny: "deny"), sound: false)
        XCTAssertLessThanOrEqual(r.content.subtitle.count, 80)
    }

    func testQuestionRequestOffersReplyOnlyForASingleOpenQuestion() {
        let one = MacNotificationContent.question(session: session, requestId: "q1", text: "Which branch?", openQuestionCount: 1, sound: true)
        XCTAssertEqual(one.identifier, "conduit.question.q1")
        XCTAssertEqual(one.content.body, "Which branch?")
        XCTAssertEqual(one.content.categoryIdentifier, "CONDUIT_QUESTION")
        let batch = MacNotificationContent.question(session: session, requestId: "q1", text: "Which branch?", openQuestionCount: 3, sound: true)
        XCTAssertEqual(batch.content.categoryIdentifier, "CONDUIT_OPEN", "a batch has no Reply; the click opens the session")
    }

    func testEmptyTitleFallsBackToConduit() {
        let s = makeSession(title: "  ")
        XCTAssertEqual(MacNotificationContent.done(session: s, turnId: "t", preview: "x", sound: false).content.title, "Conduit")
    }

    func testPayloadRoundTripsAndCarriesNoMessageText() throws {
        let dash = UUID()
        let s = makeSession(dashboard: dash)
        let r = MacNotificationContent.approval(session: s, requestId: "r9", description: "SECRET DESCRIPTION", command: "SECRET CMD", mapping: .init(approve: "once", deny: "deny"), sound: false)
        let payload = try XCTUnwrap(MacNotificationPayload(userInfo: r.content.userInfo))
        XCTAssertEqual(payload.kind, .approval)
        XCTAssertEqual(payload.sessionId, "run-1")
        XCTAssertEqual(payload.sessionKey, "key-1")
        XCTAssertEqual(payload.profile, "default")
        XCTAssertEqual(payload.dashboardID, dash)
        XCTAssertEqual(payload.requestId, "r9")
        let dump = "\(r.content.userInfo)"
        XCTAssertFalse(dump.contains("SECRET"))
    }

    func testPayloadRejectsMissingSessionId() {
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": ["kind": "done"]]))
        XCTAssertNil(MacNotificationPayload(userInfo: [:]))
    }
}
