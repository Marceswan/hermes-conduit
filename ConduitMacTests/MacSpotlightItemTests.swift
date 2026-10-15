import XCTest
@testable import ConduitMac

final class MacSpotlightItemTests: XCTestCase {
    private let dash = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func scope(_ profile: String = "default", dashboard: UUID? = nil) -> MacSpotlightScope {
        MacSpotlightScope(dashboardID: dashboard ?? dash, profile: profile)
    }

    private func summary(_ id: String, title: String = "T", source: SessionSource = .chat,
                         archived: Bool = false, count: Int? = 4, at: TimeInterval? = 1_700_000_000) -> SessionSummary {
        SessionSummary.macTestSummary(id: id, alternateIds: [], title: title, source: source,
                                      isArchived: archived, messageCount: count, lastActivityAt: at)
    }

    func testItemFields() {
        let item = MacSpotlightItemFactory.item(for: summary("s1", title: "Laravel queues"), scope: scope())
        XCTAssertEqual(item.title, "Laravel queues")
        XCTAssertTrue(item.contentDescription.contains("4"), "message count shows")
        XCTAssertEqual(item.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(item.domainIdentifier, scope().domainIdentifier)
        XCTAssertTrue(item.uniqueIdentifier.hasPrefix(scope().domainIdentifier + "|"))
    }

    func testBlankTitleFallsBack() {
        let item = MacSpotlightItemFactory.item(for: summary("s1", title: "  "), scope: scope())
        XCTAssertFalse(item.title.isEmpty)
    }

    func testDescriptionCarriesModelAndCountOnly() {
        var s = summary("s1", title: "Plans", count: 7)
        s.model = "gpt-x"
        let item = MacSpotlightItemFactory.item(for: s, scope: scope())
        XCTAssertTrue(item.contentDescription.hasPrefix("gpt-x"))
        XCTAssertTrue(item.contentDescription.contains("7"))
        XCTAssertFalse(item.contentDescription.contains("s1"), "the opaque session id is not user-facing text")
    }

    func testIdentifierRoundTripsOddSessionIDsAndProfiles() {
        for sid in ["abc", "a.b.c", "a|b|c", "id with spaces", "\u{1F600}", "x/y"] {
            for profile in ["default", "My Profile", "a|b", "p.q", "r/s", "\u{00FC}"] {
                let raw = MacSpotlightItemID.make(scope: scope(profile), sessionID: sid)
                let parsed = MacSpotlightItemID.parse(raw)
                XCTAssertEqual(parsed?.sessionID, sid, raw)
                XCTAssertEqual(parsed?.profile, profile, raw)
                XCTAssertEqual(parsed?.dashboardKey, scope(profile).dashboardKey)
            }
        }
    }

    func testNilDashboardKeyIsNone() {
        let s = MacSpotlightScope(dashboardID: nil, profile: "p")
        XCTAssertEqual(MacSpotlightItemID.parse(MacSpotlightItemID.make(scope: s, sessionID: "x"))?.dashboardKey, "none")
    }

    func testDomainIsPerProfileAndDashboard() {
        XCTAssertNotEqual(scope("a").domainIdentifier, scope("b").domainIdentifier)
        XCTAssertNotEqual(scope("a").domainIdentifier, scope("a", dashboard: UUID()).domainIdentifier)
    }

    func testMalformedIdentifiersDoNotParse() {
        for raw in ["", "nope", "conduit|only|two", "other|a|b|c", "conduit||p|s", "conduit|d|p|"] {
            XCTAssertNil(MacSpotlightItemID.parse(raw), raw)
        }
    }

    func testIndexableRules() {
        XCTAssertTrue(MacSpotlightItemFactory.isIndexable(summary("a")))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", source: .cron)))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", source: .voiceJob)))
        XCTAssertFalse(MacSpotlightItemFactory.isIndexable(summary("a", archived: true)))
    }
}
