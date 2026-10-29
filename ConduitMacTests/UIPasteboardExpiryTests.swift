import AppKit
@testable import UIKit
import XCTest
@testable import ConduitMac

/// `UIPasteboard.setItems(_:options:)` carries a credential (the speech-server key, 600 s expiry).
/// With an expiry the item must stay out of clipboard managers, and the board must clear on time.
@MainActor
final class UIPasteboardExpiryTests: XCTestCase {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private var board: NSPasteboard!
    private var shim: UIPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: .init("conduit.test.\(UUID())"))
        shim = UIPasteboard(board)
    }

    override func tearDown() {
        board.releaseGlobally()
        board = nil
        shim = nil
        super.tearDown()
    }

    private let key = "sk-test-credential"

    func testExpiryDeclaresConcealedAndTransientTypes() {
        shim.setItems([["public.utf8-plain-text": key]], options: [.expirationDate: Date().addingTimeInterval(600)])
        XCTAssertTrue(board.types?.contains(Self.concealed) == true, "\(String(describing: board.types))")
        XCTAssertTrue(board.types?.contains(Self.transient) == true, "\(String(describing: board.types))")
        XCTAssertEqual(board.string(forType: .string), key)
    }

    func testNoExpiryDeclaresNeitherType() {
        shim.setItems([["public.utf8-plain-text": key]])
        XCTAssertFalse(board.types?.contains(Self.concealed) == true)
        XCTAssertFalse(board.types?.contains(Self.transient) == true)
        XCTAssertEqual(board.string(forType: .string), key)
    }

    func testPastExpiryClearsTheBoard() {
        shim.setItems([["public.utf8-plain-text": key]], options: [.expirationDate: Date().addingTimeInterval(-1)])
        XCTAssertTrue(HostedTestSupport.waitUntil { self.board.string(forType: .string) == nil })
    }

    func testALaterCopyIsNotCleared() {
        shim.setItems([["public.utf8-plain-text": key]], options: [.expirationDate: Date().addingTimeInterval(0.3)])
        board.clearContents()
        board.setString("something else", forType: .string)
        HostedTestSupport.settle(0.8)
        XCTAssertEqual(board.string(forType: .string), "something else")
    }

    func testQuittingClearsTheBoardBeforeTheDeadline() {
        let center = NotificationCenter()
        shim.setItems([["public.utf8-plain-text": key]], options: [.expirationDate: Date().addingTimeInterval(600)],
                      terminationCenter: center)
        XCTAssertEqual(board.string(forType: .string), key)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertNil(board.string(forType: .string))
    }

    func testQuittingKeepsALaterCopy() {
        let center = NotificationCenter()
        shim.setItems([["public.utf8-plain-text": key]], options: [.expirationDate: Date().addingTimeInterval(600)],
                      terminationCenter: center)
        board.clearContents()
        board.setString("something else", forType: .string)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(board.string(forType: .string), "something else")
    }

    func testNoExpiryNeverClears() {
        let center = NotificationCenter()
        shim.setItems([["public.utf8-plain-text": key]], terminationCenter: center)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(board.string(forType: .string), key)
    }
}
