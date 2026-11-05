import AppKit
import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationRouterTests: XCTestCase {
    private var activated = 0
    private var opened: [String] = []
    private var removed: [[String]] = []
    private var dashboard: UUID?
    private var profile = "default"
    private var connected = true
    private var router: MacNotificationRouter!

    override func setUp() async throws {
        activated = 0; opened = []; removed = []; dashboard = nil; profile = "default"; connected = true
        router = MacNotificationRouter(
            activateApp: { [unowned self] in self.activated += 1 },
            openSession: { [unowned self] in self.opened.append($0) },
            activeDashboardID: { [unowned self] in self.dashboard },
            activeProfile: { [unowned self] in self.profile },
            isConnected: { [unowned self] in self.connected },
            removeNotifications: { [unowned self] in self.removed.append($0) }
        )
    }

    private func payload(dashboard: UUID? = nil, profile: String = "default") -> MacNotificationPayload {
        MacNotificationPayload(kind: .done, sessionId: "run-1", sessionKey: "key-1", profile: profile, dashboardID: dashboard, requestId: nil)
    }

    func testClickActivatesAndOpensTheDurableSessionKey() {
        router.route(payload())
        XCTAssertEqual(activated, 1)
        XCTAssertEqual(opened, ["key-1"])
        XCTAssertEqual(removed.flatMap { $0 }.sorted(), ["conduit.done.key-1"])
    }

    func testOtherDashboardOnlyActivates() {
        dashboard = UUID()
        router.route(payload(dashboard: UUID()))
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testOtherProfileOnlyActivates() {
        router.route(payload(profile: "work"))
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testColdLaunchClickIsHeldUntilConnected() {
        connected = false
        router.route(payload())
        XCTAssertEqual(activated, 1)
        XCTAssertTrue(opened.isEmpty)
        router.connectionChanged()
        XCTAssertTrue(opened.isEmpty, "still disconnected")
        connected = true
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-1"])
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-1"], "flushed once")
    }

    func testLatestHeldClickWins() {
        connected = false
        router.route(payload())
        router.route(MacNotificationPayload(kind: .done, sessionId: "run-2", sessionKey: "key-2", profile: "default", dashboardID: nil, requestId: nil))
        connected = true
        router.connectionChanged()
        XCTAssertEqual(opened, ["key-2"])
    }

    func testHeldClickIsDroppedWhenTheScopeChangedMeanwhile() {
        connected = false
        router.route(payload(profile: "work"))
        connected = true
        router.connectionChanged()
        XCTAssertTrue(opened.isEmpty, "profile default is active, the click was for work")
    }

    // MARK: visibility rules and presentation
    private let session = MacNotificationSession(sessionId: "run-1", sessionKey: "key-1", alternateIds: ["alt"], profile: "default", dashboardID: nil, title: "T")

    func testVisibilityRulesAttendedOnlyWhenEverythingHolds() {
        func eval(active: Bool = true, key: Bool = true, visible: Bool = true, sheet: Bool = false, chat: Bool = true, room: Bool = false, ids: Set<String> = ["key-1"]) -> MacNotificationVisibility {
            MacNotificationVisibilityRules.evaluate(appIsActive: active, windowIsKey: key, windowIsVisible: visible, hasAttachedSheet: sheet, chatTabShowing: chat, roomShowing: room, activeSessionIDs: ids, session: session)
        }
        XCTAssertTrue(eval().isAttended)
        XCTAssertFalse(eval(active: false).isAttended)
        XCTAssertFalse(eval(key: false).isAttended)
        XCTAssertFalse(eval(visible: false).isAttended, "minimized or fully occluded")
        XCTAssertFalse(eval(sheet: true).isAttended, "a sheet covers the chat")
        XCTAssertFalse(eval(chat: false).isAttended, "another pane")
        XCTAssertFalse(eval(room: true).isAttended, "a group room")
        XCTAssertFalse(eval(ids: ["other"]).isAttended, "another session is active (tab strip)")
        XCTAssertTrue(eval(ids: ["alt"]).isAttended, "matched through alternateIds")
        XCTAssertTrue(eval(ids: ["run-1"]).isAttended, "matched through the runtime id")
        XCTAssertFalse(eval(ids: []).isAttended, "no active session")
    }

    func testPresentationOptions() {
        let attended = MacNotificationVisibility(appIsActive: true, mainWindowKeyAndVisible: true, chatSurfaceShowing: true, sessionIsActive: true)
        XCTAssertEqual(MacNotificationPresentation.options(for: attended, sound: true), [])
        XCTAssertEqual(MacNotificationPresentation.options(for: .away, sound: true), [.banner, .list, .sound])
        XCTAssertEqual(MacNotificationPresentation.options(for: .away, sound: false), [.banner, .list])
    }
}
