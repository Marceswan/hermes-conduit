
import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class NotchDockStoreTests: XCTestCase {
    private func dock(_ edge: NSRectEdge, _ offset: CGFloat = 0.37, screen: UInt32? = 1) -> MacEdgeDock {
        MacEdgeDock(edge: edge, offset: offset, screenID: screen)
    }

    func testRoundTripForEveryEdge() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        for (i, edge) in [NSRectEdge.maxY, .minY, .minX, .maxX].enumerated() {
            let id = UInt32(10 + i)
            store.save(dock(edge, 0.37, screen: id))
            XCTAssertEqual(store.dock(forScreen: id), dock(edge, 0.37, screen: id), "\(edge)")
        }
    }

    func testPersistsUnderTheDocumentedKeyPerDisplay() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        store.save(dock(.minX, 0.5, screen: 7))
        XCTAssertNotNil(s.defaults.dictionary(forKey: "conduit.mac.notchStatus.dock.7"))
        XCTAssertNil(store.dock(forScreen: 8), "another display has its own record")
    }

    func testClearRemovesOnlyThatDisplay() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        store.save(dock(.minX, 0.5, screen: 1)); store.save(dock(.maxX, 0.5, screen: 2))
        store.clear(screenID: 1)
        XCTAssertNil(store.dock(forScreen: 1))
        XCTAssertNotNil(store.dock(forScreen: 2))
    }

    func testADockWithNoDisplayIdIsNotSaved() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        store.save(dock(.minX, 0.5, screen: nil))
        XCTAssertTrue(s.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(NotchDockStore.keyPrefix) }.isEmpty)
    }

    func testCorruptRecordsReadAsNotDocked() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        let key = NotchDockStore.keyPrefix + "1"
        s.defaults.set("junk", forKey: key)
        XCTAssertNil(store.dock(forScreen: 1), "not a dictionary")
        s.defaults.set(["edge": Int(NSRectEdge.minX.rawValue)], forKey: key)
        XCTAssertNil(store.dock(forScreen: 1), "no offset")
        s.defaults.set(["edge": 99, "offset": 0.5], forKey: key)
        XCTAssertNil(store.dock(forScreen: 1), "unknown edge")
        s.defaults.set(["edge": "left", "offset": 0.5], forKey: key)
        XCTAssertNil(store.dock(forScreen: 1), "edge is not a number")
    }

    func testOutOfRangeOffsetIsClampedNotTrusted() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        s.defaults.set(["edge": Int(NSRectEdge.minX.rawValue), "offset": 5.0], forKey: NotchDockStore.keyPrefix + "1")
        XCTAssertEqual(store.dock(forScreen: 1)?.offset, 1)
        s.defaults.set(["edge": Int(NSRectEdge.minX.rawValue), "offset": -2.0], forKey: NotchDockStore.keyPrefix + "1")
        XCTAssertEqual(store.dock(forScreen: 1)?.offset, 0)
    }

    // MARK: resolver

    func testResolverUsesTheSavedDockForAConnectedDisplay() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        store.save(dock(.maxX, 0.4, screen: 1))
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: 1, connectedScreenIDs: [1, 2], store: store), .docked(dock(.maxX, 0.4, screen: 1)))
    }

    func testResolverFallsBackToStandardWhenTheDisplayIsGoneButKeepsTheRecord() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        store.save(dock(.maxX, 0.4, screen: 9))
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: 9, connectedScreenIDs: [1], store: store), .standard)
        XCTAssertNotNil(store.dock(forScreen: 9), "applies again when the display returns")
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: 9, connectedScreenIDs: [1, 9], store: store), .docked(dock(.maxX, 0.4, screen: 9)))
    }

    func testResolverIsStandardWithoutARecordOrAScreenId() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        let store = NotchDockStore(defaults: s.defaults)
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: 1, connectedScreenIDs: [1], store: store), .standard)
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: nil, connectedScreenIDs: [1], store: store), .standard)
    }

    func testResolverTreatsACorruptRecordAsStandard() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        s.defaults.set("junk", forKey: NotchDockStore.keyPrefix + "1")
        XCTAssertEqual(NotchPlacementResolver.choose(screenID: 1, connectedScreenIDs: [1], store: NotchDockStore(defaults: s.defaults)), .standard)
    }
}
