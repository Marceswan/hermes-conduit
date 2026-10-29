import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteRecentsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws { HostedTestSupport.dropSuite(suite) }

    func testRecordMovesToFrontAndDedupes() {
        var r = MacPaletteRecents()
        r.record("command:a"); r.record("slash:b"); r.record("command:a")
        XCTAssertEqual(r.ids, ["command:a", "slash:b"])
    }

    func testCapsAtTwenty() {
        var r = MacPaletteRecents()
        for i in 0..<25 { r.record("command:\(i)") }
        XCTAssertEqual(r.ids.count, MacPaletteRecents.limit)
        XCTAssertEqual(r.ids.first, "command:24")
        XCTAssertEqual(r.ids.last, "command:5")
    }

    func testInitClampsAndDedupes() {
        let r = MacPaletteRecents(ids: (0..<30).map { "command:\($0 % 25)" })
        XCTAssertEqual(r.ids.count, MacPaletteRecents.limit)
        XCTAssertEqual(Set(r.ids).count, r.ids.count)
    }

    func testResolvedDropsItemsThatNoLongerExistInRecencyOrder() {
        var r = MacPaletteRecents()
        r.record("session:a"); r.record("slash:b"); r.record("session:gone")   // most recent first: gone, b, a
        let items = [MacPaletteItem.fixture("A", kind: .session, id: "session:a"), .fixture("B", kind: .slash, id: "slash:b")]
        XCTAssertEqual(r.resolved(in: items).map(\.id), ["slash:b", "session:a"])
    }

    func testStorageKeyAndPerScopePersistence() {
        let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(MacPaletteRecentsStore.storageKey(dashboardID: dashboard, profile: "default"),
                       "conduit.mac.palette.recents.00000000-0000-0000-0000-000000000002.default")
        XCTAssertEqual(MacPaletteRecentsStore.storageKey(dashboardID: nil, profile: "work"), "conduit.mac.palette.recents.none.work")

        let store = MacPaletteRecentsStore(defaults: suite.defaults)
        var a = MacPaletteRecents(); a.record("command:x")
        store.save(a, dashboardID: nil, profile: "default")
        XCTAssertEqual(store.load(dashboardID: nil, profile: "default").ids, ["command:x"])
        XCTAssertEqual(store.load(dashboardID: nil, profile: "work").ids, [])
        XCTAssertEqual(MacPaletteRecentsStore(defaults: suite.defaults).load(dashboardID: nil, profile: "default").ids, ["command:x"])
    }
}
