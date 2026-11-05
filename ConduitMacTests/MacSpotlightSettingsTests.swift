import XCTest
@testable import ConduitMac

@MainActor
final class MacSpotlightSettingsTests: XCTestCase {
    func testToggleOnIndexesAndOffRemovesEverything() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let fake = FakeSearchableIndex()
        let indexer = MacSpotlightIndexer(index: fake, defaults: suite.defaults)
        indexer.setScope(MacSpotlightScope(dashboardID: nil, profile: "default"), catalog: [])
        let catalog = [SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A", lastActivityAt: 1)]
        let model = MacSpotlightSettingsModel(indexer: indexer, catalog: { catalog })
        XCTAssertFalse(model.isOn, "off by default")
        XCTAssertTrue(fake.indexed.isEmpty, "nothing is indexed before opt-in")
        model.setOn(true)
        XCTAssertTrue(model.isOn)
        XCTAssertEqual(fake.indexed.last?.count, 1)
        XCTAssertTrue(suite.defaults.bool(forKey: MacSpotlightIndexer.enabledKey))
        model.setOn(false)
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(fake.deleteAllCount, 1)
        XCTAssertFalse(suite.defaults.bool(forKey: MacSpotlightIndexer.enabledKey))
    }

    func testRemoveAllButtonDeletesWithoutChangingTheToggle() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let fake = FakeSearchableIndex()
        let model = MacSpotlightSettingsModel(indexer: MacSpotlightIndexer(index: fake, defaults: suite.defaults), catalog: { [] })
        model.setOn(true)
        model.removeAll()
        XCTAssertEqual(fake.deleteAllCount, 1)
        XCTAssertTrue(model.isOn)
    }

    func testModelReflectsAPersistedOptIn() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(true, forKey: MacSpotlightIndexer.enabledKey)
        let model = MacSpotlightSettingsModel(
            indexer: MacSpotlightIndexer(index: FakeSearchableIndex(), defaults: suite.defaults), catalog: { [] })
        XCTAssertTrue(model.isOn)
    }
}
