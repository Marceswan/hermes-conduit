import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteViewTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func store(sessions: Int = 3, unread: Set<String> = [], running: Bool = false) -> MacPaletteStore {
        let store = MacPaletteStore(defaults: suite.defaults)
        let snapshot = MacPaletteSnapshot(
            sessions: (0..<sessions).map { .paletteFixture(id: "s\($0)", title: "Session number \($0)") },
            unreadSessionIDs: unread, activeSessionID: "s0", profiles: ["default"], activeProfile: "default",
            isTurnRunning: running
        )
        store.snapshot = { snapshot }
        return store
    }

    private func host(_ store: MacPaletteStore, appearance: NSAppearance.Name? = nil) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let view = ZStack { Color.gray.opacity(0.2) }.overlay { MacPaletteView(store: store) }
        let window = HostedTestSupport.host(view.frame(width: 800, height: 600), size: NSSize(width: 800, height: 600))
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        self.window = window
        return window
    }

    private func hasLabel(_ window: NSWindow, containing text: String) -> Bool {
        AccessibilityProbe.labels(in: window).contains { $0.contains(text) }
    }

    func testMetrics() {
        XCTAssertEqual(MacPaletteMetrics.width, 560)
        XCTAssertEqual(MacPaletteMetrics.maxVisibleRows, 9)
    }

    func testNothingRendersWhileClosed() throws {
        let window = try host(store())
        HostedTestSupport.settle(0.3)
        XCTAssertFalse(hasLabel(window, containing: "Session number"))
    }

    func testRowsAreAccessibleButtonsWithTitleAndSelectedRowFirst() throws {
        let store = store()
        let window = try host(store)
        store.present()
        store.query = "number"
        XCTAssertTrue(HostedTestSupport.waitUntil { hasLabel(window, containing: "Session number 0") })
        XCTAssertEqual(store.selectionID, "session:s0")
        let row = AccessibilityProbe.nodes(in: window).first { $0.label == "Session number 0" }
        XCTAssertEqual(row?.role, NSAccessibility.Role.button.rawValue)
    }

    func testSearchFieldIsLabelledAndFocusedOnOpen() throws {
        let store = store()
        let window = try host(store)
        store.present()
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder is NSTextView || window.firstResponder is NSTextField })
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains(AppLocalization.string("Command palette search")) })
    }

    func testSelectedRowStaysVisibleAfterDownAtOverflow() throws {
        let store = store(sessions: 40)
        let window = try host(store)
        store.present()
        store.query = "#"
        XCTAssertTrue(HostedTestSupport.waitUntil { hasLabel(window, containing: "Session number 0") })
        // One key press per run-loop turn, as a user types: the view follows each change.
        for _ in 0..<30 { store.move(.down); HostedTestSupport.settle(0.02) }
        XCTAssertEqual(store.selectionID, "session:s30")
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.frame(of: "Session number 30", in: window).map { frame in
                CGRect(origin: .zero, size: window.contentView!.bounds.size).contains(frame)
            } ?? false
        })
    }

    func testEmptyResultsShowTheEmptyState() throws {
        let store = store()
        let window = try host(store)
        store.present()
        store.query = "zzzzqqq"
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains(AppLocalization.string("No results")) })
        store.runSelected()    // nothing selected: must not crash
        XCTAssertTrue(store.isPresented)
    }

    func testRendersInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let store = store()
            let window = try host(store, appearance: appearance)
            store.present()
            HostedTestSupport.settle(0.2)
            let view = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            HostedTestSupport.tearDown(window)
            self.window = nil
        }
    }

    func testKeyEventsReachTheStore() throws {
        let store = store()
        let window = try host(store)
        store.present()
        store.query = "#"
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder is NSTextView })
        func send(_ keyCode: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
            window.sendEvent(event)
        }
        send(125, chars: "\u{F701}")                  // Down
        XCTAssertTrue(HostedTestSupport.waitUntil { store.selectionID == "session:s1" })
        send(126, chars: "\u{F700}")                  // Up
        XCTAssertTrue(HostedTestSupport.waitUntil { store.selectionID == "session:s0" })
        send(53, chars: "\u{1B}")                     // Esc clears "#"
        XCTAssertTrue(HostedTestSupport.waitUntil { store.query.isEmpty })
        send(53, chars: "\u{1B}")                     // second Esc closes
        XCTAssertTrue(HostedTestSupport.waitUntil { !store.isPresented })
    }

    func testReturnOnlyRunsThroughSubmitNotAKeyHandler() throws {
        // An IME confirmation must not run the row: Return reaches the store
        // only via the field's onSubmit. Committing text with no marked text
        // runs the selected row exactly once.
        let store = store()
        var opened: [String] = []
        store.calls.openSession = { opened.append($0) }
        let window = try host(store)
        store.present()
        store.query = "number 1"
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder is NSTextView })
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(event)
        XCTAssertTrue(HostedTestSupport.waitUntil { opened == ["s1"] })
    }

    func testConfirmationReplacesTheListAndIsReadable() throws {
        let store = store(running: true)
        let window = try host(store)
        store.present()
        store.query = "stop response"
        XCTAssertTrue(HostedTestSupport.waitUntil { hasLabel(window, containing: "Stop Response") })
        store.runSelected()
        XCTAssertTrue(HostedTestSupport.waitUntil { hasLabel(window, containing: AppLocalization.string("Stop the current response?")) })
        // The heading is exposed with a label; the message and hint are static
        // text (read by VoiceOver as values), and the two buttons carry labels.
        XCTAssertTrue(hasLabel(window, containing: AppLocalization.string("Cancel")))
        XCTAssertTrue(AccessibilityProbe.nodes(in: window).contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == AppLocalization.string("Stop") })
        XCTAssertFalse(hasLabel(window, containing: "Switch Model"), "the list is replaced, not stacked")
        store.handleEscape()
        XCTAssertTrue(HostedTestSupport.waitUntil { !hasLabel(window, containing: AppLocalization.string("Stop the current response?")) })
    }

    func testAnUnreadRowSaysSoToVoiceOver() throws {
        let store = store(unread: ["s1"])
        let window = try host(store)
        store.present()
        store.query = "number"
        let unread = AppLocalization.string("Unread")
        XCTAssertTrue(HostedTestSupport.waitUntil { hasLabel(window, containing: "Session number 1, \(unread)") })
        XCTAssertFalse(hasLabel(window, containing: "Session number 2, \(unread)"))
    }

    func testRowLabelJoinsTitleSubtitleReasonAndUnread() {
        var item = MacPaletteItem.fixture("Title", kind: .slash)
        XCTAssertEqual(MacPaletteRow.label(for: item), "Title")
        item.subtitle = "Sub"; item.disabledReason = "No active chat"; item.isUnread = true
        XCTAssertEqual(MacPaletteRow.label(for: item), "Title, Sub, No active chat, \(AppLocalization.string("Unread"))")
    }
}
