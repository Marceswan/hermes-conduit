import SwiftUI
import XCTest
@testable import ConduitMac

/// `MessageBubble` and the step rows stop with a precondition failure outside `.chatRows()`
/// (upstream 2.x). A session window reuses them, so one row of each reused kind is laid out here.
@MainActor
final class MacSessionWindowChatRowsTests: XCTestCase {
    private func controller() -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true) }
        return MacSessionWindowController(
            token: MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "s"),
            environment: env, hub: MacStreamEventHub())
    }

    private func layOut(_ message: ChatMessage, scheme: ColorScheme, file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: MacSessionWindowRow(message: message, controller: controller())
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .environment(\.colorScheme, scheme)
            .frame(width: 560))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0, "\(message.role) row did not lay out", file: file, line: line)
    }

    func testUserRowLaysOutInTheSessionWindow() {
        let message = ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: "2026-10-21T00:00:00Z")
        for scheme in [ColorScheme.light, .dark] { layOut(message, scheme: scheme) }
    }

    /// `MessageBubble` reads `rowActions.required` for a partial reply (the read-aloud controller):
    /// without `.chatRows()` above the row this stops with a precondition failure.
    func testPartialReplyRowLaysOutInTheSessionWindow() {
        let message = ChatMessage(id: "p1", role: .partial, content: "Working on it", timestamp: "2026-10-21T00:00:00Z")
        for scheme in [ColorScheme.light, .dark] { layOut(message, scheme: scheme) }
    }

    func testToolRowLaysOutInTheSessionWindow() {
        var message = ChatMessage(id: "t1", role: .tool, content: "", timestamp: "2026-10-21T00:00:00Z")
        message.tool = ToolActivity(id: "t1", name: "read_file", input: nil, output: nil, status: .complete)
        for scheme in [ColorScheme.light, .dark] { layOut(message, scheme: scheme) }
    }

    func testAssistantRowLaysOutInTheSessionWindow() {
        let message = ChatMessage(id: "a1", role: .assistant, content: "Hello **there**", timestamp: "2026-10-21T00:00:00Z")
        for scheme in [ColorScheme.light, .dark] { layOut(message, scheme: scheme) }
    }
}
