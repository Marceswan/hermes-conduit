import XCTest
@testable import ConduitMac

final class MacNotificationPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLongRunningBoundary() {
        XCTAssertFalse(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(29.9), threshold: 30))
        XCTAssertTrue(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(30), threshold: 30))
        XCTAssertTrue(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(120), threshold: 120))
        XCTAssertFalse(MacNotificationPolicy.isLongRunning(startedAt: t0, finishedAt: t0.addingTimeInterval(-5), threshold: 10),
                       "a clock that ran backwards is never long-running")
    }

    func testThresholdChoicesAndDefault() {
        XCTAssertEqual(MacNotificationPolicy.thresholdChoices, [10, 30, 60, 120])
        XCTAssertEqual(MacNotificationPolicy.defaultThreshold, 30)
    }

    func testSuppressionTruthTable() {
        func v(_ a: Bool, _ k: Bool, _ c: Bool, _ s: Bool) -> MacNotificationVisibility {
            MacNotificationVisibility(appIsActive: a, mainWindowKeyAndVisible: k, chatSurfaceShowing: c, sessionIsActive: s)
        }
        XCTAssertTrue(MacNotificationPolicy.shouldSuppress(v(true, true, true, true)))
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(false, true, true, true)), "app in background")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, false, true, true)), "window not key or occluded")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, true, false, true)), "another pane or a sheet covers chat")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(v(true, true, true, false)), "another session is active (tab strip)")
        XCTAssertFalse(MacNotificationPolicy.shouldSuppress(.away))
    }

    func testIdentifiers() {
        XCTAssertEqual(MacNotificationPolicy.ID.done("k1"), "conduit.done.k1")
        XCTAssertEqual(MacNotificationPolicy.ID.approval("r1"), "conduit.approval.r1")
        XCTAssertEqual(MacNotificationPolicy.ID.question("r2"), "conduit.question.r2")
        XCTAssertEqual(MacNotificationPolicy.ID.thread("k1"), "session-k1")
        XCTAssertEqual(MacNotificationPolicy.ID.doneSummary, "conduit.done.summary")
        let u = UUID()
        XCTAssertEqual(MacNotificationPolicy.ID.notice(u), "conduit.notice.\(u.uuidString)")
    }

    func testPostedSetAbsorbsReplaysPerSlot() {
        var set = MacNotificationPostedSet()
        XCTAssertTrue(set.insert(.done, "t1"))
        XCTAssertFalse(set.insert(.done, "t1"))
        XCTAssertTrue(set.insert(.approval, "t1"), "slots are independent")
        XCTAssertTrue(set.insert(.done, "t2"))
    }

    func testBurstCollapsesFromTheFourthInsideTenSeconds() {
        var limiter = MacDoneBurstLimiter()
        XCTAssertEqual(limiter.register(at: t0), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(1)), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(2)), .individual)
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(3)), .summary(count: 4))
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(4)), .summary(count: 5))
    }

    func testBurstWindowSlides() {
        var limiter = MacDoneBurstLimiter()
        for i in 0..<3 { _ = limiter.register(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(limiter.register(at: t0.addingTimeInterval(12)), .individual,
                       "the first three are older than 10 s by then")
    }

    func testSessionAllIDsCoversRuntimeKeyAndAlternates() {
        let s = MacNotificationSession(sessionId: "run", sessionKey: "key", alternateIds: ["alt"], profile: "default", dashboardID: nil, title: "T")
        XCTAssertEqual(s.allIDs, ["run", "key", "alt"])
    }
}
