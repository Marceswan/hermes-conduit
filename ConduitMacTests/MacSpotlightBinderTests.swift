import XCTest
@testable import ConduitMac

@MainActor
final class MacSpotlightBinderTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var index: FakeSearchableIndex!
    private var catalog: [SessionSummary] = []
    private var archived: [SessionSummary] = []
    private var binder: MacSpotlightBinder!
    private let scope = MacSpotlightScope(dashboardID: nil, profile: "default")

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        index = FakeSearchableIndex()
        catalog = []
        archived = []
        binder = MacSpotlightBinder(
            indexer: MacSpotlightIndexer(index: index, defaults: suite.defaults),
            debounce: 0.05,
            catalog: { [unowned self] in self.catalog },
            archived: { [unowned self] in self.archived }
        )
        binder.indexer.setEnabled(true, catalog: [])
        binder.scopeDidChange(scope)
    }
    override func tearDown() async throws {
        binder = nil; index = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func row(_ id: String) -> SessionSummary { .macTestSummary(id: id, alternateIds: [], title: id, lastActivityAt: 1) }

    func testDebounceCoalescesBurstsIntoOneIndexCall() {
        for i in 0..<5 {
            catalog.append(row("s\(i)"))
            binder.catalogDidChange()
        }
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(index.indexed.count, 1)
        XCTAssertEqual(index.indexed.first?.count, 5)
    }

    func testDeletionIsAMutationWhoseRowLeftTheCatalog() {
        catalog = [row("a")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        binder.mutationDidChange(to: "a")
        catalog = []
        binder.mutationDidChange(to: nil)
        XCTAssertEqual(index.deletedIDs.last, [MacSpotlightItemID.make(scope: scope, sessionID: "a")])
    }

    func testRenameIsNotADeletion() {
        catalog = [row("a")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        binder.mutationDidChange(to: "a")
        binder.mutationDidChange(to: nil)
        XCTAssertTrue(index.deletedIDs.isEmpty)
    }

    func testArchiveLeavesSpotlightThroughTheArchivedList() {
        catalog = [row("a"), row("b")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        binder.mutationDidChange(to: "a")
        catalog = [row("b")]
        archived = [SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "a", isArchived: true)]
        binder.archivedDidChange()
        binder.mutationDidChange(to: nil)
        XCTAssertEqual(index.deletedIDs.count, 1, "removed once, by the archive path")
        XCTAssertEqual(index.deletedIDs.last, [MacSpotlightItemID.make(scope: scope, sessionID: "a")])
    }

    func testPageAbsenceThroughTheDebouncedPathRemovesNothing() {
        catalog = [row("a"), row("b")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        catalog = [row("a")]
        binder.catalogDidChange()
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(index.deletedIDs.isEmpty)
    }

    func testDashboardSwitchWithTheSameProfileMovesTheIndex() {
        catalog = [row("a")]
        binder.catalogDidChange()
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty })
        let other = MacSpotlightScope(dashboardID: UUID(), profile: "default")
        catalog = []
        binder.scopeDidChange(other)
        XCTAssertEqual(index.deletedDomains.last, [scope.domainIdentifier])
    }

    func testScopeChangeCancelsAPendingSyncForTheOldScope() {
        catalog = [row("old")]
        binder.catalogDidChange()
        let other = MacSpotlightScope(dashboardID: nil, profile: "work")
        catalog = [row("new")]
        binder.scopeDidChange(other)
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(index.allIndexedIDs, [MacSpotlightItemID.make(scope: other, sessionID: "new")])
    }

    func testAScopePublishThatChangesNothingKeepsThePendingSync() {
        catalog = [row("a")]
        binder.catalogDidChange()
        // The dashboard registry republishes (metadata only): same scope.
        binder.scopeDidChange(scope)
        XCTAssertTrue(HostedTestSupport.waitUntil { !self.index.indexed.isEmpty },
                      "the debounced sync must still run")
        XCTAssertEqual(index.allIndexedIDs, [MacSpotlightItemID.make(scope: scope, sessionID: "a")])
    }
}
