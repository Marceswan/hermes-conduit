import SwiftUI
import XCTest
@testable import ConduitMac

/// `MessageBubble`, `StreamingBubble` and the step rows stop with a precondition failure outside
/// `.chatRows()` (upstream 2.x). A session window reuses them, so the window's transcript rows are
/// laid out here with each reused row kind.
@MainActor
final class MacSessionWindowChatRowsTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        super.tearDown()
    }

    private struct Harness: View {
        let controller: MacSessionWindowController
        @State private var follow = MacTranscriptFollowPolicy()
        var body: some View {
            ScrollView { MacSessionWindowTranscriptRows(controller: controller, follow: $follow).padding(16) }
        }
    }

    private func controller(messages: [ChatMessage]) async -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true) }
        env.resume = { _ in SessionResumeResult(sessionId: "rt", storedSessionId: nil, messages: messages,
                                                snapshot: .macTestSnapshot(running: false)) }
        let c = MacSessionWindowController(
            token: MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "s"),
            environment: env, hub: MacStreamEventHub())
        c.start()
        for _ in 0..<20 { await Task.yield() }
        return c
    }

    private func layOut(_ c: MacSessionWindowController, scheme: ColorScheme) {
        let host = Harness(controller: c)
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .environment(\.colorScheme, scheme)
        let window = HostedTestSupport.host(host, size: NSSize(width: 640, height: 900))
        self.window = window
        HostedTestSupport.settle(0.5)
        XCTAssertGreaterThan(window.contentView?.fittingSize.height ?? 0, 0)
        HostedTestSupport.tearDown(window)
        self.window = nil
    }

    private static let at = "2026-10-21T00:00:00Z"

    /// `MessageBubble` reads `rowActions.required` for a partial reply (the read-aloud controller).
    func testPartialReplyRowLaysOutInTheSessionWindow() async {
        let c = await controller(messages: [ChatMessage(id: "p1", role: .partial, content: "Working on it", timestamp: Self.at)])
        for scheme in [ColorScheme.light, .dark] { layOut(c, scheme: scheme) }
    }

    func testEveryReusedRowKindLaysOutInTheSessionWindow() async {
        var tool = ChatMessage(id: "t1", role: .tool, content: "", timestamp: Self.at)
        tool.tool = ToolActivity(id: "t1", name: "read_file", input: nil, output: nil, status: .complete)
        let c = await controller(messages: [
            ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: Self.at),
            ChatMessage(id: "a1", role: .assistant, content: "Hello **there**", timestamp: Self.at),
            tool
        ])
        for scheme in [ColorScheme.light, .dark] { layOut(c, scheme: scheme) }
    }

    /// A streamed reply that holds a gateway media path: `StreamingBubble` builds a media loader that
    /// calls `rowActions.required`, and it draws the agent name from `rowState`. Outside `.chatRows()`
    /// the name is blank, so the accessibility tree is the oracle.
    func testStreamingReplyWithAMediaPathShowsTheAgentUnderChatRows() async throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        AccessibilityTreeBoost.set(true)
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        let appState = AppStateRuntimeRegistry.shared.appState
        let name = appState.conversationAgentIdentity.name
        try XCTSkipIf(name.isEmpty)
        let c = await controller(messages: [])
        c.handle(.messageDelta(sessionId: "rt", text: "Here is the chart:\n\nMEDIA:/tmp/conduit-test-chart.png\n"))
        XCTAssertFalse(c.transcript.streamingText.isEmpty)
        let host = Harness(controller: c).environmentObject(appState)
        let window = HostedTestSupport.host(host, size: NSSize(width: 640, height: 900))
        self.window = window
        func texts() -> [String] { AccessibilityProbe.nodes(in: window).flatMap { [$0.value, $0.label].compactMap { $0 } } }
        let found = HostedTestSupport.waitUntil { texts().contains("Responding") }
        HostedTestSupport.settle(0.5)
        XCTAssertTrue(found, "the streaming bubble did not draw")
        XCTAssertTrue(texts().contains(name), "agent name \(name) missing: \(texts())")
    }

    func testVoiceCallMarkerRowLaysOutInTheSessionWindow() async {
        var marker = ChatMessage(id: "m1", role: .system, content: "Voice call", timestamp: Self.at)
        marker.displayKind = VoiceCallChatLink.displayKind
        var origin = ChatMessage(id: "m2", role: .system, content: "Voice call", timestamp: Self.at)
        origin.displayKind = VoiceCallChatLink.originDisplayKind
        let c = await controller(messages: [marker, origin])
        for scheme in [ColorScheme.light, .dark] { layOut(c, scheme: scheme) }
    }
}
