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

    // MARK: approval integrity

    private let both = MacApprovalChoiceMapper.Mapping(approve: "once", deny: "deny")

    func testApprovalStatesTheCommandFirstAndKeepsTheSessionTitleSecondary() {
        let r = MacNotificationContent.approval(session: session, requestId: "r9", description: "Run a shell command", command: "rm -rf build", mapping: both, sound: true)
        XCTAssertEqual(r.identifier, "conduit.approval.r9")
        XCTAssertEqual(r.content.title, "Approval needed", "a fixed title: no agent text can sit where the approval is named")
        XCTAssertEqual(r.content.body, "rm -rf build\nRun a shell command", "the command being approved leads")
        XCTAssertEqual(r.content.subtitle, "Refactor billing", "the session title is secondary")
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL")
    }

    func testSessionTitleCannotImpersonateTheApprovalTitle() {
        let spoof = makeSession(title: "Approval needed: harmless\u{202E}\nrm -rf ~")
        let r = MacNotificationContent.approval(session: spoof, requestId: "r", description: "d", command: "ls", mapping: both, sound: false)
        XCTAssertEqual(r.content.title, "Approval needed")
        XCTAssertFalse(r.content.subtitle.contains("\u{202E}"))
        XCTAssertFalse(r.content.subtitle.contains("\n"))
    }

    func testApprovalCategoryFollowsTheMapping() {
        let denyOnly = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: "deny"), sound: true)
        XCTAssertEqual(denyOnly.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        let none = MacNotificationContent.approval(session: session, requestId: "r9", description: "d", command: "c", mapping: .init(approve: nil, deny: nil), sound: true)
        XCTAssertEqual(none.content.categoryIdentifier, "CONDUIT_OPEN")
    }

    func testTruncatedCommandDropsInlineApproveButKeepsDenyAndOpen() {
        let long = String(repeating: "x", count: MacNotificationContent.commandLimit + 1)
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: long, mapping: both, sound: false)
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        XCTAssertTrue(r.content.body.contains("\u{2026}"))
        let fits = String(repeating: "x", count: MacNotificationContent.inlineApproveLimit)
        let ok = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: fits, mapping: both, sound: false)
        XCTAssertEqual(ok.content.categoryIdentifier, "CONDUIT_APPROVAL", "a command that fits in full keeps Approve")
    }

    func testCommandLongerThanABannerClipDropsInlineApproveEvenWhenTheBodyShowsItWhole() {
        // Shown in full in the body (<= commandLimit) but past what a banner shows before clipping.
        let mid = String(repeating: "x", count: MacNotificationContent.inlineApproveLimit + 1)
        XCTAssertLessThanOrEqual(mid.count, MacNotificationContent.commandLimit)
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: mid, mapping: both, sound: false)
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        XCTAssertTrue(r.content.body.hasPrefix(mid), "the body still shows it whole")
        XCTAssertFalse(MacNotificationContent.commandIsFaithful(mid))
        XCTAssertTrue(MacNotificationContent.commandIsFaithful(String(repeating: "x", count: MacNotificationContent.inlineApproveLimit)))
    }

    func testApprovalPayloadBindsTheExactCommandWithoutCarryingItsText() throws {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: "SECRET CMD", mapping: both, itemId: "approval:r", sound: false)
        let payload = try XCTUnwrap(MacNotificationPayload(userInfo: r.content.userInfo))
        XCTAssertEqual(payload.commandDigest, MacNotificationContent.commandDigest("SECRET CMD"))
        XCTAssertNotEqual(MacNotificationContent.commandDigest("SECRET CMD"), MacNotificationContent.commandDigest("SECRET CMD "))
        XCTAssertEqual(MacNotificationContent.commandDigest("SECRET CMD").count, 64)
        XCTAssertFalse("\(r.content.userInfo)".contains("SECRET"))
        let done = MacNotificationContent.done(session: session, turnId: "t", preview: "p", sound: false)
        XCTAssertNil(try XCTUnwrap(MacNotificationPayload(userInfo: done.content.userInfo)).commandDigest)
    }

    func testCommandThatNeededSanitizingDropsInlineApprove() {
        for hostile in ["ls\u{202E} -la", "ls\u{200B}-la", "echo a\nrm -rf ~", "ls\u{0007}"] {
            let r = MacNotificationContent.approval(session: session, requestId: "r", description: "d", command: hostile, mapping: both, sound: false)
            XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY", hostile.debugDescription)
        }
    }

    func testEmptyCommandNeverOffersApprove() {
        let r = MacNotificationContent.approval(session: session, requestId: "r", description: "Needs approval", command: "  ", mapping: both, sound: false)
        XCTAssertEqual(r.content.categoryIdentifier, "CONDUIT_APPROVAL_DENY")
        XCTAssertEqual(r.content.body, "Needs approval")
    }

    func testCommandIsFaithfulRule() {
        XCTAssertTrue(MacNotificationContent.commandIsFaithful("  swift test  "), "edge whitespace is not a change")
        XCTAssertFalse(MacNotificationContent.commandIsFaithful(""))
        XCTAssertFalse(MacNotificationContent.commandIsFaithful("a\nb"))
        XCTAssertFalse(MacNotificationContent.commandIsFaithful(String(repeating: "y", count: 400)))
    }

    func testEveryAgentControlledStringIsSanitized() {
        let dirty = "x\u{202E}y\u{200B}z\nw"
        let done = MacNotificationContent.done(session: makeSession(title: dirty), turnId: "t", preview: dirty, sound: false)
        XCTAssertEqual(done.content.title, "xyz w")
        XCTAssertEqual(done.content.body, "xyz w")
        let q = MacNotificationContent.question(session: session, requestId: "q", text: dirty, openQuestionCount: 1, sound: false)
        XCTAssertEqual(q.content.body, "xyz w")
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

    func testPayloadCarriesTheFeedsExactItemId() throws {
        let a = MacNotificationContent.approval(session: session, requestId: "q1", description: "d", command: "ls", mapping: both, itemId: "approval:q1", sound: false)
        XCTAssertEqual(try XCTUnwrap(MacNotificationPayload(userInfo: a.content.userInfo)).itemId, "approval:q1")
        let q = MacNotificationContent.question(session: session, requestId: "c1", text: "t", openQuestionCount: 1, itemId: "clarify:c1", sound: false)
        XCTAssertEqual(try XCTUnwrap(MacNotificationPayload(userInfo: q.content.userInfo)).itemId, "clarify:c1")
        XCTAssertNil(try XCTUnwrap(MacNotificationPayload(userInfo: MacNotificationContent.done(session: session, turnId: "t", preview: "p", sound: false).content.userInfo)).itemId)
    }

    func testPayloadRejectsMissingSessionId() {
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": ["kind": "done", "profile": "default"]]))
        XCTAssertNil(MacNotificationPayload(userInfo: [:]))
    }

    func testPayloadFailsClosedOnAMissingOrUnknownKindOrProfile() {
        let ok: [String: Any] = ["kind": "done", "session_id": "run-1", "profile": "default"]
        XCTAssertNotNil(MacNotificationPayload(userInfo: ["conduit_mac": ok]))
        var noKind = ok; noKind["kind"] = nil
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": noKind]), "a missing kind must not default to Done (which can send a reply)")
        var oddKind = ok; oddKind["kind"] = "reply-all"
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": oddKind]))
        var noProfile = ok; noProfile["profile"] = nil
        XCTAssertNil(MacNotificationPayload(userInfo: ["conduit_mac": noProfile]), "a missing profile must not default to the default profile")
    }
}
