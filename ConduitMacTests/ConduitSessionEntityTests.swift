import XCTest
@testable import ConduitMac

final class ConduitSessionEntityTests: XCTestCase {
    private func s(_ id: String, _ title: String, profile: String? = "default", at: TimeInterval = 1) -> SessionSummary {
        SessionSummary.intentTestSummary(id: id, title: title, profile: profile, lastActivityAt: at)
    }

    func testSuggestionsAreNewestFirstAndLimited() {
        let list = [s("a", "A", at: 1), s("b", "B", at: 3), s("c", "C", at: 2)]
        XCTAssertEqual(ConduitSessionCatalog.suggestions(list, limit: 2).map(\.id), ["b", "c"])
    }

    func testResolveByIdWorksWithAnEmptyCatalog() {
        let resolved = ConduitSessionCatalog.resolve(["x"], in: [])
        XCTAssertEqual(resolved.map(\.id), ["x"], "a saved shortcut must resolve when the app was just launched")
        XCTAssertNil(resolved.first?.profile)
    }

    func testResolveUsesTheTitleWhenListedAndMatchesAlternateIds() {
        let row = SessionSummary.intentTestSummary(id: "real", alternateIds: ["draft"], title: "Real", lastActivityAt: 1)
        XCTAssertEqual(ConduitSessionCatalog.resolve(["draft"], in: [row]).first?.id, "real")
        XCTAssertEqual(ConduitSessionCatalog.resolve(["real"], in: [row]).first?.title, "Real")
    }

    func testResolveKeepsTheListedRowsProfile() {
        let row = s("a", "A", profile: "work")
        XCTAssertEqual(ConduitSessionCatalog.resolve(["a"], in: [row]).first?.profile, "work")
    }

    func testMatchingIsCaseInsensitiveOnTitle() {
        let list = [s("a", "Laravel queues"), s("b", "Swift tips")]
        XCTAssertEqual(ConduitSessionCatalog.matching("LARA", in: list).map(\.id), ["a"])
        XCTAssertEqual(ConduitSessionCatalog.matching("", in: list).count, 2)
    }

    func testBlankTitleDisplaysAFallback() {
        XCTAssertFalse(ConduitSessionCatalog.suggestions([s("a", "  ")], limit: 5).first!.title.isEmpty)
    }

    @MainActor
    func testOpenSessionIntentEnqueuesTheSessionAndItsProfile() async throws {
        _ = MacIntentInbox.shared.take()
        let intent = OpenSessionIntent(session: ConduitSessionEntity(id: "s1", title: "T", profile: "work"))
        _ = try await intent.perform()
        XCTAssertEqual(MacIntentInbox.shared.take(), .openSession(id: "s1", profile: "work"))
    }
}

extension SessionSummary {
    /// A minimal summary for intent tests. Separate from `macTestSummary` so
    /// parallel work on that helper cannot conflict with this file.
    static func intentTestSummary(
        id: String, alternateIds: [String] = [], title: String,
        profile: String? = "default", lastActivityAt: TimeInterval? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: nil, alternateIds: alternateIds, title: title, model: "",
            updatedLabel: "", lastActivityAt: lastActivityAt, profile: profile, source: .chat,
            isActive: false, isArchived: false, lineageRootId: nil
        )
    }
}
