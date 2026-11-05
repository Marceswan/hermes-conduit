import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The Mac twin of upstream's browser sign-in sheet (`AuthWebView.asSignInSheet()`, called by the shared
/// `Login/LoginScreens.swift`): the page under a bar with a Cancel button. The button sits in a toolbar item that
/// the accessibility tree of a hosted window does not expose, so the test checks the bar and the title.
@MainActor
final class AuthWebSignInSheetTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        if let window {
            window.contentViewController = nil
            window.close()
        }
        window = nil
        super.tearDown()
    }

    func testSheetHasABarWithOneItemAndTheSignInTitle() throws {
        // An empty address fails normalization, so the page never loads and no request leaves the test.
        let sheet = AuthWebView(url: "", cloudflareAccess: nil, onTicket: { _, _ in }, onError: { _, _ in })
            .asSignInSheet()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: sheet)
        window.orderFront(nil)
        self.window = window
        // SwiftUI hosts the Cancel button inside one toolbar item and the title in the window title.
        XCTAssertTrue(HostedTestSupport.waitUntil { window.toolbar?.items.count == 1 },
                      "toolbar items: \(window.toolbar?.items.count ?? -1)")
        XCTAssertTrue(HostedTestSupport.waitUntil { window.title == "Sign in" }, "title: \(window.title)")
    }
}
