import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabsStoreTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacSessionTabsStore!
    private var opened: [String] = []
    private var newChats = 0
    private var emptyChat = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacSessionTabsStore(defaults: suite.defaults)
        opened = []; newChats = 0; emptyChat = false
        store.openSession = { [unowned self] in self.opened.append($0) }
        store.startNewChat = { [unowned self] in self.newChats += 1 }
        store.activeChatIsEmpty = { [unowned self] in self.emptyChat }
        store.setScope(dashboardID: nil, profile: "default")
    }

    override func tearDown() async throws {
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    func testActiveSessionChangeAddsATab() {
        store.activeSessionChanged("a", title: "A")
        store.activeSessionChanged("b", title: "B")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(store.model.activeID, "b")
        store.activeSessionChanged(nil, title: nil)
        XCTAssertNil(store.model.activeID, "a room or nothing open: no tab selected")
    }

    func testSelectOpensOnceAndActiveTabScrollsToTop() {
        var scrolled = 0
        store.scrollActiveToTop = { scrolled += 1 }
        store.activeSessionChanged("a", title: "A")
        store.activeSessionChanged("b", title: "B")
        store.select("a")
        XCTAssertEqual(opened, ["a"])
        store.activeSessionChanged("a", title: "A")
        store.select("a")
        XCTAssertEqual(opened, ["a"], "the active tab does not reopen")
        XCTAssertEqual(scrolled, 1)
    }

    func testCloseActiveOpensNeighbour() {
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
        store.select("b"); store.activeSessionChanged("b", title: "b")
        opened = []
        store.close(nil)
        XCTAssertEqual(opened, ["c"])
    }

    func testCloseLastStartsNewChatUnlessAlreadyEmpty() {
        store.activeSessionChanged("a", title: "A")
        emptyChat = true
        store.close(nil)
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"], "an empty last chat stays")
        XCTAssertEqual(newChats, 0)
        emptyChat = false
        store.close(nil)
        XCTAssertTrue(store.model.tabs.isEmpty)
        XCTAssertEqual(newChats, 1)
    }

    func testReopenOpensTheSession() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        store.close("a")
        opened = []
        store.reopen()
        XCTAssertEqual(opened, ["a"])
    }

    func testShortcutsAndNeighbours() {
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
        store.selectShortcut(1)
        store.selectShortcut(9)  // c is active: no open
        store.selectNeighbor(.next)
        XCTAssertEqual(opened, ["a", "a"])
    }

    func testPersistsPerScopeAndRestores() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0.uppercased()) }
        store.setScope(dashboardID: nil, profile: "work")
        XCTAssertTrue(store.model.tabs.isEmpty)
        store.activeSessionChanged("w", title: "W")
        store.setScope(dashboardID: nil, profile: "default")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(store.model.tabs.map(\.title), ["A", "B"])

        let reloaded = MacSessionTabsStore(defaults: suite.defaults)
        reloaded.setScope(dashboardID: nil, profile: "work")
        XCTAssertEqual(reloaded.model.tabs.map(\.id), ["w"])
        XCTAssertEqual(reloaded.model.activeID, "w")
    }

    func testStaleStoredActiveIDIsCleared() throws {
        let key = MacSessionTabsStore.storageKey(dashboardID: nil, profile: "stale")
        let stale = #"{"tabs":[{"id":"a","title":"A","unavailable":false}],"activeID":"gone"}"#
        suite.defaults.set(Data(stale.utf8), forKey: key)
        store.setScope(dashboardID: nil, profile: "stale")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"])
        XCTAssertNil(store.model.activeID, "an active id outside the tabs is stale")
    }

    func testNilTitleKeepsAnExistingTabsTitle() {
        store.activeSessionChanged("old", title: "Old")
        store.activeSessionChanged("b", title: "B")
        store.activeSessionChanged("old", title: nil)
        XCTAssertEqual(store.model.tabs.map(\.title), ["Old", "B"])
        XCTAssertEqual(store.model.activeID, "old")
    }

    func testStorageKey() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(MacSessionTabsStore.storageKey(dashboardID: id, profile: "default"),
                       "conduit.mac.sessionTabs.00000000-0000-0000-0000-000000000001.default")
        XCTAssertEqual(MacSessionTabsStore.storageKey(dashboardID: nil, profile: "p"), "conduit.mac.sessionTabs.none.p")
    }

    func testOpenFailureMarksUnavailableAndDeleteRemoves() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        store.openFailed("a")
        XCTAssertTrue(store.model.tabs[0].unavailable)
        store.sessionDeleted("a")
        XCTAssertEqual(store.model.tabs.map(\.id), ["b"])
    }

    func testCatalogRekeysAndRetitlesButNeverPrunes() {
        store.activeSessionChanged("draft", title: "New conversation")
        store.activeSessionChanged("old", title: "Old")
        let real = SessionSummary.macTestSummary(id: "real", alternateIds: ["draft"], title: "Laravel")
        store.catalogChanged([real])
        XCTAssertEqual(store.model.tabs.map(\.id), ["real", "old"], "old is outside the loaded page, not deleted")
        XCTAssertEqual(store.model.tabs[0].title, "Laravel")
    }
}

final class MacSessionDeletionDetectorTests: XCTestCase {
    func testDeletionIsAMutationWhoseSessionLeftTheCatalog() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        XCTAssertNil(detector.mutationChanged(to: "a", catalog: [a], archived: []))
        XCTAssertEqual(detector.mutationChanged(to: nil, catalog: [], archived: []), "a")
    }

    func testRenameIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        _ = detector.mutationChanged(to: "a", catalog: [a], archived: [])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: [a], archived: []))
    }

    func testArchiveIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        _ = detector.mutationChanged(to: "a", catalog: [a], archived: [])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: [], archived: [a]))
    }

    func testUnarchiveIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        _ = detector.mutationChanged(to: "a", catalog: [], archived: [a])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: [a], archived: []))
    }

    func testUnlistedMutationIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        _ = detector.mutationChanged(to: "x", catalog: [], archived: [])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: [], archived: []))
    }
}

extension SessionSummary {
    /// A minimal summary for tab tests.
    static func macTestSummary(id: String, alternateIds: [String], title: String) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: nil, alternateIds: alternateIds, title: title, model: "",
            updatedLabel: "", profile: "default", source: .chat, isActive: false,
            isArchived: false, lineageRootId: nil
        )
    }
}
