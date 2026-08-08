import XCTest
@testable import Conduit

final class KanbanBoardSelectionStoreTests: XCTestCase {

    func testPersistsSelectionPerServer() {
        let (defaults, _) = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)

        store.setSelectedBoard("ops", forServer: "https://alpha.example")
        store.setSelectedBoard("research", forServer: "https://beta.example")

        XCTAssertEqual(store.selectedBoard(forServer: "https://alpha.example"), "ops")
        XCTAssertEqual(store.selectedBoard(forServer: "https://beta.example"), "research")
    }

    func testNilSelectionClearsEntry() {
        let (defaults, _) = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)

        store.setSelectedBoard("ops", forServer: "https://alpha.example")
        store.setSelectedBoard(nil, forServer: "https://alpha.example")

        XCTAssertNil(store.selectedBoard(forServer: "https://alpha.example"))
    }

    func testUnknownServerReturnsNil() {
        let (defaults, _) = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)

        XCTAssertNil(store.selectedBoard(forServer: "https://never-seen.example"))
    }

    func testRoundTripsThroughFreshStoreInstance() {
        let (defaults, _) = makeDefaults()
        KanbanBoardSelectionStore(defaults: defaults).setSelectedBoard("ops", forServer: "https://alpha.example")

        let reloaded = KanbanBoardSelectionStore(defaults: defaults)

        XCTAssertEqual(reloaded.selectedBoard(forServer: "https://alpha.example"), "ops")
    }

    func testServerKeyNormalizationIgnoresCaseAndWhitespace() {
        let (defaults, _) = makeDefaults()
        let store = KanbanBoardSelectionStore(defaults: defaults)

        store.setSelectedBoard("ops", forServer: "https://Alpha.Example")

        XCTAssertEqual(store.selectedBoard(forServer: " https://alpha.example "), "ops")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "kanban-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (defaults, suite)
    }
}
