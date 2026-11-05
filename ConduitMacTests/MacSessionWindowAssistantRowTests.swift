import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// D21 final review: an assistant row in a session window must not carry upstream's Quote, Branch,
/// React or Read aloud controls (they act on the MAIN window's AppState). The accessibility tree is
/// the oracle; a control from upstream's own bubble proves the probe can see such controls at all.
@MainActor
final class MacSessionWindowAssistantRowTests: XCTestCase {
    private var boostWasOn = false
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    private let message = ChatMessage(id: "a1", role: .assistant, content: "Hello **there**", timestamp: "2026-10-16T00:00:00Z")

    private func buttonLabels<V: View>(of view: V) throws -> [String] {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let appState = AppStateRuntimeRegistry.shared.appState
        let host = view.environmentObject(appState).frame(width: 560, height: 300)
        let window = HostedTestSupport.host(host, size: NSSize(width: 560, height: 300))
        self.window = window
        HostedTestSupport.settle(0.4)
        var labels: [String] = []
        // The tree builds lazily: wait for the first control, then let it finish.
        _ = HostedTestSupport.waitUntil {
            labels = AccessibilityProbe.nodes(in: window)
                .filter { $0.role == NSAccessibility.Role.button.rawValue }.compactMap(\.label)
            return !labels.isEmpty
        }
        HostedTestSupport.settle(0.3)
        return AccessibilityProbe.nodes(in: window)
            .filter { $0.role == NSAccessibility.Role.button.rawValue }.compactMap(\.label)
    }

    func testProbeSeesUpstreamsAssistantControls() throws {
        let appState = AppStateRuntimeRegistry.shared.appState
        let labels = try buttonLabels(of: AssistantBubble(message: message, readAloudController: appState.messageReadAloudController,
                                                           gatewayResolver: nil))
        XCTAssertTrue(labels.contains(AppLocalization.string("Quote this response")), "\(labels)")
        XCTAssertTrue(labels.contains("Branch from this response"), "\(labels)")
    }

    func testWindowAssistantRowOffersCopyOnly() throws {
        let labels = try buttonLabels(of: MacWindowAssistantRow(message: message, profile: "default", gatewayResolver: nil))
        XCTAssertEqual(labels, [AppLocalization.string("Copy response")], "\(labels)")
        for forbidden in [AppLocalization.string("Quote this response"), "Branch from this response",
                          AppLocalization.string("Read response aloud")] {
            XCTAssertFalse(labels.contains(forbidden), forbidden)
        }
    }

    func testCopyButtonWritesTheResponseToThePasteboard() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var row = MacWindowAssistantRow(message: message, profile: "default", gatewayResolver: nil)
        row.pasteboard = board
        let host = row.environmentObject(AppStateRuntimeRegistry.shared.appState).frame(width: 560, height: 300)
        let window = HostedTestSupport.host(host, size: NSSize(width: 560, height: 300))
        self.window = window
        let copy = AppLocalization.string("Copy response")
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains(copy) })
        XCTAssertTrue(AccessibilityProbe.press(copy, in: window))
        XCTAssertTrue(HostedTestSupport.waitUntil { board.string(forType: .string) == "Hello **there**" })
    }

    func testCopyHelperWritesPlainText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        MacWindowAssistantRow.copy("abc", to: board)
        XCTAssertEqual(board.string(forType: .string), "abc")
    }

    func testVoiceCallMarkersAreNotRoutedToTheMainWindowCards() {
        var row = ChatMessage(id: "v", role: .system, content: "call", timestamp: "")
        XCTAssertFalse(MacSessionWindowView.isVoiceCallMarker(row))
        row.displayKind = VoiceCallChatLink.displayKind
        XCTAssertTrue(MacSessionWindowView.isVoiceCallMarker(row))
        row.displayKind = VoiceCallChatLink.originDisplayKind
        XCTAssertTrue(MacSessionWindowView.isVoiceCallMarker(row))
    }

    // MARK: Follow policy

    func testFollowsWhileAtTheBottom() {
        let policy = MacTranscriptFollowPolicy()
        XCTAssertTrue(policy.shouldFollow(userJustSent: false), "a window opens following")
    }

    func testStopsFollowingWhenTheReaderScrollsUp() {
        var policy = MacTranscriptFollowPolicy()
        policy.bottomVisibilityChanged(false)
        XCTAssertFalse(policy.shouldFollow(userJustSent: false), "a streaming delta must not yank the transcript down")
        policy.bottomVisibilityChanged(true)
        XCTAssertTrue(policy.shouldFollow(userJustSent: false), "back at the bottom: follows again")
    }

    func testSendingAlwaysFollows() {
        var policy = MacTranscriptFollowPolicy()
        policy.bottomVisibilityChanged(false)
        XCTAssertTrue(policy.shouldFollow(userJustSent: true))
    }

    // MARK: Card text

    func testApprovalWithdrawnReasonIsSanitizedForTheCard() {
        XCTAssertNil(MacWindowApprovalCard.displayError(nil))
        XCTAssertNil(MacWindowApprovalCard.displayError(""))
        let hostile = "timed out\u{202E}evil" + String(repeating: "x", count: 5000)
        let shown = MacWindowApprovalCard.displayError(hostile) ?? ""
        XCTAssertFalse(shown.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(shown.count, 301)
    }
}
