import UserNotifications
import XCTest
@testable import ConduitMac

@MainActor
final class MacNotificationCategoriesTests: XCTestCase {
    func testOurCategoriesAndTheirActions() {
        let byID = Dictionary(uniqueKeysWithValues: MacNotificationCategories.ours().map { ($0.identifier, $0) })
        XCTAssertEqual(Set(byID.keys), ["CONDUIT_DONE", "CONDUIT_OPEN", "CONDUIT_APPROVAL", "CONDUIT_APPROVAL_DENY", "CONDUIT_APPROVAL_APPROVE", "CONDUIT_QUESTION"])
        XCTAssertEqual(byID["CONDUIT_DONE"]?.actions.map(\.identifier), ["conduit.action.reply", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_QUESTION"]?.actions.map(\.identifier), ["conduit.action.reply", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_APPROVAL"]?.actions.map(\.identifier), ["conduit.action.approve", "conduit.action.deny", "conduit.action.open"])
        XCTAssertEqual(byID["CONDUIT_OPEN"]?.actions.map(\.identifier), ["conduit.action.open"])
    }

    func testReplyIsATextInputThatDoesNotForegroundTheApp() throws {
        let done = try XCTUnwrap(MacNotificationCategories.ours().first { $0.identifier == "CONDUIT_DONE" })
        let reply = try XCTUnwrap(done.actions.first { $0.identifier == "conduit.action.reply" })
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertFalse(reply.options.contains(.foreground))
    }

    func testApproveAndDenyRequireAuthenticationAndDoNotForeground() throws {
        let approval = try XCTUnwrap(MacNotificationCategories.ours().first { $0.identifier == "CONDUIT_APPROVAL" })
        for id in ["conduit.action.approve", "conduit.action.deny"] {
            let action = try XCTUnwrap(approval.actions.first { $0.identifier == id })
            XCTAssertTrue(action.options.contains(.authenticationRequired), id)
            XCTAssertFalse(action.options.contains(.foreground), id)
        }
        let open = try XCTUnwrap(approval.actions.first { $0.identifier == "conduit.action.open" })
        XCTAssertTrue(open.options.contains(.foreground))
    }

    func testNoCategoryOffersAlwaysOrSession() {
        for category in MacNotificationCategories.ours() {
            for action in category.actions {
                XCTAssertFalse(action.identifier.contains("always") || action.identifier.contains("session"))
            }
        }
    }

    func testApprovalCategorySelection() {
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: "once", deny: "deny")), "CONDUIT_APPROVAL")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: nil, deny: "deny")), "CONDUIT_APPROVAL_DENY")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: "once", deny: nil)), "CONDUIT_APPROVAL_APPROVE")
        XCTAssertEqual(MacNotificationCategories.approvalCategory(for: .init(approve: nil, deny: nil)), "CONDUIT_OPEN")
    }

    func testRegisterMergesWithForeignCategoriesInsteadOfReplacingThem() async {
        let center = FakeNotificationCenter()
        let foreign = UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])
        center.stored = [foreign]
        await MacNotificationCategories.register(on: center)
        XCTAssertTrue(center.stored.contains { $0.identifier == "HERMES_CALL" }, "HermesCallNotifications' category survives")
        XCTAssertTrue(center.stored.contains { $0.identifier == "CONDUIT_DONE" })
    }

    func testRegisterIsIdempotentAndReplacesOurStaleCopiesOnly() async {
        let center = FakeNotificationCenter()
        let stale = UNNotificationCategory(identifier: "CONDUIT_DONE", actions: [], intentIdentifiers: [], options: [])
        center.stored = [stale]
        await MacNotificationCategories.register(on: center)
        await MacNotificationCategories.register(on: center)
        let done = center.stored.filter { $0.identifier == "CONDUIT_DONE" }
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.actions.count, 2, "the stale empty copy was replaced by the current one (re-register on language change)")
        XCTAssertEqual(center.stored.count, MacNotificationCategories.ours().count)
    }
}
