import XCTest
@testable import ConduitMac

@MainActor
final class FakeSearchableIndex: SearchableIndexing {
    var indexed: [[MacSpotlightItem]] = []
    var deletedIDs: [[String]] = []
    var deletedDomains: [[String]] = []
    var deleteAllCount = 0
    var allIndexedIDs: [String] { indexed.flatMap { $0 }.map(\.uniqueIdentifier) }
    func index(_ items: [MacSpotlightItem]) { indexed.append(items) }
    func delete(ids: [String]) { deletedIDs.append(ids) }
    func delete(domains: [String]) { deletedDomains.append(domains) }
    func deleteAll() { deleteAllCount += 1 }
}

@MainActor
final class MacSpotlightIndexerTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var index: FakeSearchableIndex!
    private var indexer: MacSpotlightIndexer!
    private let scopeA = MacSpotlightScope(dashboardID: nil, profile: "default")
    private let scopeB = MacSpotlightScope(dashboardID: nil, profile: "work")

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        index = FakeSearchableIndex()
        indexer = MacSpotlightIndexer(index: index, defaults: suite.defaults)
    }
    override func tearDown() async throws {
        indexer = nil; index = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func s(_ id: String, _ title: String = "T", at: TimeInterval = 100) -> SessionSummary {
        SessionSummary.macTestSummary(id: id, alternateIds: [], title: title, lastActivityAt: at)
    }
    private func enabled(scope: MacSpotlightScope? = nil, _ catalog: [SessionSummary] = []) {
        indexer.setEnabled(true, catalog: catalog)
        indexer.setScope(scope ?? scopeA, catalog: catalog)
    }
    private func id(_ session: String, in scope: MacSpotlightScope? = nil) -> String {
        MacSpotlightItemID.make(scope: scope ?? scopeA, sessionID: session)
    }

    func testDisabledByDefaultIndexesNothing() {
        indexer.setScope(scopeA, catalog: [])
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.indexed.isEmpty)
        XCTAssertFalse(indexer.isEnabled)
    }

    func testInitialIndexThenOnlyChangedRowsReindex() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        XCTAssertEqual(index.indexed.last?.count, 2)
        index.indexed = []
        indexer.catalogChanged([s("a"), s("b")])
        XCTAssertTrue(index.indexed.allSatisfy(\.isEmpty), "unchanged catalog does nothing")
        indexer.catalogChanged([s("a", "Renamed"), s("b")])
        XCTAssertEqual(index.indexed.last?.map(\.title), ["Renamed"])
    }

    func testActivityChangeReindexes() {
        enabled()
        indexer.catalogChanged([s("a", at: 1)])
        index.indexed = []
        indexer.catalogChanged([s("a", at: 2)])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testAbsenceFromThePageRemovesNothing() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.deletedIDs.allSatisfy(\.isEmpty), "a paged catalog hides rows without deleting them")
        index.indexed = []
        indexer.catalogChanged([s("a"), s("b")])
        XCTAssertTrue(index.indexed.allSatisfy(\.isEmpty), "a row that comes back is still indexed, not re-sent")
    }

    func testSessionDeletedRemovesOneItemAndForgetsIt() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        indexer.sessionDeleted("a")
        XCTAssertEqual(index.deletedIDs.last, [id("a")])
        index.indexed = []
        indexer.catalogChanged([s("b")])
        XCTAssertTrue(index.indexed.allSatisfy(\.isEmpty))
    }

    func testDeletingAnUnindexedSessionDeletesNothing() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.sessionDeleted("never-indexed")
        XCTAssertTrue(index.deletedIDs.isEmpty)
    }

    func testArchivedRowInTheCatalogIsRemoved() {
        enabled()
        indexer.catalogChanged([s("a")])
        let archived = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "T", isArchived: true, lastActivityAt: 100)
        indexer.catalogChanged([archived])
        XCTAssertEqual(index.deletedIDs.last, [id("a")])
    }

    func testSessionsMovedToTheArchivedListAreRemoved() {
        enabled()
        indexer.catalogChanged([s("a"), s("b")])
        let archived = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "T", isArchived: true, lastActivityAt: 100)
        indexer.sessionsArchived([archived])
        XCTAssertEqual(index.deletedIDs.last, [id("a")])
        index.indexed = []
        indexer.catalogChanged([s("b")])
        XCTAssertTrue(index.indexed.allSatisfy(\.isEmpty), "b is still indexed, a is gone")
    }

    func testArchivedRowThatWasNeverIndexedDeletesNothing() {
        enabled()
        indexer.catalogChanged([s("b")])
        indexer.sessionsArchived([SessionSummary.macTestSummary(id: "z", alternateIds: [], title: "Z", isArchived: true)])
        XCTAssertTrue(index.deletedIDs.isEmpty)
    }

    func testRestoredSessionIsIndexedAgain() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.sessionsArchived([SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "T", isArchived: true)])
        index.indexed = []
        indexer.catalogChanged([s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testIdentityChangeRemovesTheOldIdentity() {
        enabled()
        indexer.catalogChanged([s("old")])
        let moved = SessionSummary.macTestSummary(id: "new", alternateIds: ["old"], title: "T", lastActivityAt: 100)
        indexer.catalogChanged([moved])
        XCTAssertEqual(index.deletedIDs.last, [id("old")])
        XCTAssertEqual(index.indexed.last?.first?.uniqueIdentifier, id("new"))
    }

    func testProfileSwitchDeletesOldDomainAndIndexesNew() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setScope(scopeB, catalog: [s("w")])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
        XCTAssertEqual(index.indexed.last?.first?.domainIdentifier, scopeB.domainIdentifier)
        indexer.setScope(scopeA, catalog: [s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1, "switching back re-indexes from scratch")
    }

    func testDashboardSwitchWithTheSameProfileDeletesOldDomain() {
        let other = MacSpotlightScope(dashboardID: UUID(), profile: "default")
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setScope(other, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
    }

    func testSettingTheSameScopeAgainDoesNothing() {
        enabled()
        indexer.catalogChanged([s("a")])
        let before = index.deletedDomains.count
        indexer.setScope(scopeA, catalog: [s("a")])
        XCTAssertEqual(index.deletedDomains.count, before)
    }

    func testScopeChangeAfterRelaunchDeletesTheStaleDomain() {
        enabled()
        let relaunched = MacSpotlightIndexer(index: index, defaults: suite.defaults)
        relaunched.setScope(scopeB, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
    }

    func testNilScopeDeletesTheCurrentDomain() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setScope(nil, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
        index.indexed = []
        indexer.catalogChanged([s("a")])
        XCTAssertTrue(index.indexed.isEmpty, "signed out: nothing indexes")
    }

    func testToggleOffDeletesEverythingAndLaterChangesIndexNothing() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.setEnabled(false, catalog: [])
        XCTAssertEqual(index.deleteAllCount, 1)
        index.indexed = []
        indexer.catalogChanged([s("b")])
        XCTAssertTrue(index.indexed.isEmpty)
    }

    func testToggleOffForgetsEveryScopeSnapshotSoToggleOnReindexesAll() {
        enabled()
        indexer.catalogChanged([s("a")])
        // A snapshot left behind by another scope (for example after a relaunch signed out).
        let stale = try! JSONEncoder().encode(["w": ["title": "T"]])
        suite.defaults.set(stale, forKey: scopeB.snapshotKey)
        indexer.setEnabled(false, catalog: [])
        XCTAssertNil(suite.defaults.data(forKey: scopeA.snapshotKey))
        XCTAssertNil(suite.defaults.data(forKey: scopeB.snapshotKey))
        XCTAssertNotNil(suite.defaults.object(forKey: MacSpotlightIndexer.enabledKey), "the toggle itself is kept")
        index.indexed = []
        indexer.setScope(scopeB, catalog: [])
        indexer.setEnabled(true, catalog: [s("w")])
        XCTAssertEqual(index.indexed.last?.count, 1, "the wiped index is refilled, not trusted from an old snapshot")
    }

    func testToggleOnAfterOffStillCleansTheStaleDomainAfterRelaunch() {
        enabled()
        indexer.setEnabled(false, catalog: [])
        indexer.setEnabled(true, catalog: [s("a")])
        let relaunched = MacSpotlightIndexer(index: index, defaults: suite.defaults)
        relaunched.setScope(scopeB, catalog: [])
        XCTAssertEqual(index.deletedDomains.last, [scopeA.domainIdentifier])
    }

    func testToggleOnIndexesTheCurrentCatalog() {
        indexer.setScope(scopeA, catalog: [])
        indexer.setEnabled(true, catalog: [s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testRemoveAllWhileEnabledKeepsTheToggleAndRefillsOnNextChange() {
        enabled()
        indexer.catalogChanged([s("a")])
        indexer.removeAll()
        XCTAssertEqual(index.deleteAllCount, 1)
        XCTAssertTrue(indexer.isEnabled)
        index.indexed = []
        indexer.catalogChanged([s("a")])
        XCTAssertEqual(index.indexed.last?.count, 1)
    }

    func testCapKeepsTheNewest() {
        enabled()
        let catalog = (0..<(MacSpotlightIndexer.itemCap + 50)).map { s("s\($0)", at: TimeInterval($0)) }
        indexer.catalogChanged(catalog)
        let ids = index.allIndexedIDs
        XCTAssertEqual(ids.count, MacSpotlightIndexer.itemCap)
        XCTAssertTrue(ids.contains(id("s\(MacSpotlightIndexer.itemCap + 49)")))
        XCTAssertFalse(ids.contains(id("s0")))
    }

    func testCapHoldsAcrossPagesByEvictingTheOldest() {
        enabled()
        let first = (0..<MacSpotlightIndexer.itemCap).map { s("s\($0)", at: TimeInterval($0 + 10)) }
        indexer.catalogChanged(first)
        // A newer page arrives; s0 (oldest) must make room, the rest stay.
        let newer = (0..<3).map { s("n\($0)", at: TimeInterval(5_000 + $0)) }
        indexer.catalogChanged(first + newer)
        XCTAssertEqual(Set(index.deletedIDs.last ?? []), [id("s0"), id("s1"), id("s2")])
        XCTAssertEqual(index.indexed.last?.count, 3)
    }

    func testNonIndexableRowsAreSkipped() {
        enabled()
        let cron = SessionSummary.macTestSummary(id: "c", alternateIds: [], title: "job", source: .cron)
        indexer.catalogChanged([cron])
        XCTAssertTrue(index.indexed.allSatisfy(\.isEmpty))
    }

    func testSnapshotSurvivesRelaunchSoNothingReindexes() {
        enabled()
        indexer.catalogChanged([s("a")])
        let fake = FakeSearchableIndex()
        let again = MacSpotlightIndexer(index: fake, defaults: suite.defaults)
        again.setScope(scopeA, catalog: [s("a")])
        XCTAssertTrue(fake.indexed.allSatisfy(\.isEmpty))
        XCTAssertTrue(fake.deletedDomains.isEmpty)
    }
}
