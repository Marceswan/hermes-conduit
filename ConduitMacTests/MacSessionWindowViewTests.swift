import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionWindowViewTests: XCTestCase {
    private func controller(phase setup: (inout MacSessionWindowEnvironment) -> Void = { _ in }) -> MacSessionWindowController {
        var env = MacSessionWindowEnvironment()
        env.scope = { MacSessionWindowScope(dashboardID: nil, profile: "default", connected: true) }
        env.resume = { _ in SessionResumeResult(sessionId: "rt", storedSessionId: nil,
            messages: [ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: "2026-10-16T00:00:00Z")],
            snapshot: .macTestSnapshot(running: false)) }
        setup(&env)
        return MacSessionWindowController(token: MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "s"),
                                          environment: env, hub: MacStreamEventHub())
    }

    func testRendersInLightAndDark() async throws {
        let c = controller()
        c.start()
        for _ in 0..<20 { await Task.yield() }
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: MacSessionWindowView(controller: c)
                .environmentObject(AppStateRuntimeRegistry.shared.appState)
                .environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 760)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testStopShowsWhileRunning() async {
        let c = controller()
        c.start()
        for _ in 0..<20 { await Task.yield() }
        c.handle(.sessionBusy(sessionId: "rt", busy: true))
        XCTAssertEqual(MacSessionWindowComposer.primaryAction(for: c), .stop)
        c.handle(.sessionBusy(sessionId: "rt", busy: false))
        XCTAssertEqual(MacSessionWindowComposer.primaryAction(for: c), .send)
    }

    func testBannerTextPerPhase() {
        XCTAssertNil(MacSessionWindowView.bannerText(for: .ready, profileName: { $0 }))
        XCTAssertEqual(MacSessionWindowView.bannerText(for: .disconnected, profileName: { $0 }),
                       AppLocalization.string("Not connected to Hermes"))
        XCTAssertTrue(MacSessionWindowView.bannerText(for: .wrongScope("work"), profileName: { $0.uppercased() })?
            .contains("WORK") ?? false)
    }

    func testComposerFollowsMainRouteByDefault() {
        let view = ComposerPasteTextView(text: .constant(""), isFocused: .constant(false), measuredHeight: .constant(0),
                                         enabled: true, onPastedImage: { _ in }, onPastedImageError: { _ in },
                                         editorIdentity: UUID())
        XCTAssertTrue(view.followsMainRoute)
    }

    func testBannerTextForRemainingPhases() {
        XCTAssertEqual(MacSessionWindowView.bannerText(for: .failed("Boom"), profileName: { $0 }), "Boom")
        XCTAssertEqual(MacSessionWindowView.bannerText(for: .deleted, profileName: { $0 }),
                       AppLocalization.string("This conversation was deleted."))
        XCTAssertNotNil(MacSessionWindowView.bannerText(for: .loading, profileName: { $0 }))
    }

    func testApprovalChoicesFollowUpstreamRules() {
        var a = ApprovalActivity.macTest(requestId: "r")
        XCTAssertTrue(MacWindowApprovalCard.allows("once", for: a))
        XCTAssertTrue(MacWindowApprovalCard.allows("session", for: a))
        XCTAssertFalse(MacWindowApprovalCard.allows("always", for: a))
        a.allowPermanent = true
        XCTAssertTrue(MacWindowApprovalCard.allows("always", for: a))
        a.choices = ["once", "deny"]
        XCTAssertFalse(MacWindowApprovalCard.allows("session", for: a))
        XCTAssertEqual(MacWindowApprovalCard.label(for: "deny"), AppLocalization.string("Rejected"))
    }

    func testCardsRenderInEveryState() {
        var approval = ApprovalActivity.macTest(requestId: "r")
        let clarify = ClarifyActivity(requestId: "c", questions: [
            ClarifyQuestion(id: "q1", question: "Which?", choices: [ClarifyChoice(label: "A", value: "a")]),
            ClarifyQuestion(id: "q2", question: "Why?", choices: []),
            ClarifyQuestion(id: "q3", question: "Done?", choices: [], status: .answered, answer: "yes")])
        let prompt = InputPromptActivity(requestId: "p", sessionId: "s", kind: .sudo, command: "sudo ls")
        var views: [AnyView] = []
        for status in [ApprovalActivity.Status.pending, .submitting, .approved, .rejected, .expired, .error] {
            approval.status = status
            approval.error = status == .error ? "nope" : nil
            views.append(AnyView(MacWindowApprovalCard(activity: approval, onChoose: { _ in })))
        }
        views.append(AnyView(MacWindowClarifyCard(activity: clarify, onAnswer: { _, _ in })))
        var expired = clarify
        expired.isExpired = true
        views.append(AnyView(MacWindowClarifyCard(activity: expired, onAnswer: { _, _ in })))
        for status in [InputPromptActivity.Status.pending, .submitting, .submitted, .skipped, .expired, .error] {
            var p = prompt
            p.status = status
            views.append(AnyView(MacWindowInputPromptCard(activity: p, onSubmit: { _ in })))
        }
        for view in views {
            let host = NSHostingView(rootView: view.frame(width: 560))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testWindowRendersCardRowsAndStreamingText() async {
        let c = controller { env in
            env.resume = { _ in SessionResumeResult(sessionId: "rt", storedSessionId: nil,
                messages: [ChatMessage(id: "a1", role: .approval, content: "", timestamp: "2026-10-16T00:00:00Z",
                                       approval: .macTest(requestId: "r1"))],
                snapshot: .macTestSnapshot(running: false)) }
        }
        c.start()
        for _ in 0..<20 { await Task.yield() }
        c.handle(.messageDelta(sessionId: "rt", text: "streaming..."))
        let host = NSHostingView(rootView: MacSessionWindowView(controller: c)
            .environmentObject(AppStateRuntimeRegistry.shared.appState))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 760)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(MacSessionWindowComposer.primaryAction(for: c), .stop)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
