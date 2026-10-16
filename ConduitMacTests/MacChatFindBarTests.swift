import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindBarTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
    }

    private func openController(hits: [ChatMessage] = []) -> MacChatFindController {
        MacChatFindController(
            environment: .init(messages: { hits }, hasEarlierMessages: { false }, isTranscriptShown: { true }),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
    }

    // MARK: key mapping (the field decides, AppKit-side)

    func testReturnStepsForwardAndShiftReturnBackward() {
        let ret = #selector(NSResponder.insertNewline(_:))
        XCTAssertEqual(MacChatFindField.Coordinator.command(for: ret, hasMarkedText: false, shift: false), .next)
        XCTAssertEqual(MacChatFindField.Coordinator.command(for: ret, hasMarkedText: false, shift: true), .previous)
    }

    func testEscapeCloses() {
        XCTAssertEqual(
            MacChatFindField.Coordinator.command(for: #selector(NSResponder.cancelOperation(_:)), hasMarkedText: false, shift: false),
            .close
        )
    }

    func testNothingIsHandledWhileAnIMECompositionIsMarked() {
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertNil(MacChatFindField.Coordinator.command(for: selector, hasMarkedText: true, shift: false))
            XCTAssertNil(MacChatFindField.Coordinator.command(for: selector, hasMarkedText: true, shift: true))
        }
    }

    func testOtherCommandsFallThroughToTheFieldEditor() {
        XCTAssertNil(MacChatFindField.Coordinator.command(for: #selector(NSResponder.moveLeft(_:)), hasMarkedText: false, shift: false))
        XCTAssertNil(MacChatFindField.Coordinator.command(for: #selector(NSResponder.deleteBackward(_:)), hasMarkedText: false, shift: false))
    }

    func testOptionAndControlReturnVariantsStepToo() {
        for name in ["insertNewlineIgnoringFieldEditor:", "insertLineBreak:"] {
            XCTAssertEqual(
                MacChatFindField.Coordinator.command(for: NSSelectorFromString(name), hasMarkedText: false, shift: false),
                .next, name
            )
        }
    }

    // MARK: coordinator -> controller

    func testTypingUpdatesTheControllersQuery() {
        let controller = openController()
        controller.open()
        let coordinator = MacChatFindField.Coordinator(controller: controller)
        let field = NSSearchField()
        field.stringValue = "needle"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(controller.query, "needle")
        field.stringValue = ""
        coordinator.fieldAction(field)   // the cancel (x) button
        XCTAssertEqual(controller.query, "")
    }

    func testDoCommandRunsTheMappedAction() async {
        let hits = [
            ChatMessage(id: "m1", role: .assistant, content: "needle", timestamp: ""),
            ChatMessage(id: "m2", role: .assistant, content: "needle", timestamp: ""),
        ]
        let controller = openController(hits: hits)
        controller.open()
        controller.query = "needle"
        await controller.settled()
        let coordinator = MacChatFindField.Coordinator(controller: controller)
        let field = NSSearchField()
        let editor = NSTextView()
        XCTAssertEqual(controller.state.position, 2)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(controller.state.position, 1, "Return went to the next hit (wrapped)")
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }

    // MARK: hosted bar

    func testOpeningShowsTheBarAndFocusesTheField() {
        let controller = openController()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        XCTAssertNil(controller.field, "closed: no field mounted")
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field?.window != nil })
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.ownsResponder(window.firstResponder) },
                      "the field took focus")
    }

    func testOpeningFocusesTheFieldAndSelectsTheLastQuery() {
        let controller = openController()
        controller.query = "abc"   // typed in an earlier session of the bar
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field?.stringValue == "abc" })
        XCTAssertTrue(HostedTestSupport.waitUntil {
            controller.ownsResponder(window.firstResponder)
                && (window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 0, length: 3)
        })
        _ = window.makeFirstResponder(nil)
        controller.open()   // Cmd-F again while the bar is open
        XCTAssertTrue(HostedTestSupport.waitUntil {
            controller.ownsResponder(window.firstResponder)
                && (window.firstResponder as? NSTextView)?.selectedRange == NSRange(location: 0, length: 3)
        })
    }

    func testClosingRemovesTheBar() {
        let controller = openController()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field != nil })
        controller.close()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field == nil })
    }

    func testTheBarExposesLabelledControls() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let boostWasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        AccessibilityTreeBoost.set(true)
        let controller = openController()
        controller.open()
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        XCTAssertTrue(HostedTestSupport.waitUntil {
            let labels = AccessibilityProbe.labels(in: window)
            return ["Previous match", "Next match", "Done"].allSatisfy(labels.contains)
        }, "labels: \(AccessibilityProbe.labels(in: window))")
    }

    func testTheSlotShowsNothingWithoutAControllerAndTheBarWithOne() {
        let none = HostedTestSupport.host(MacChatFindSlot().frame(width: 400, height: 60), size: NSSize(width: 400, height: 60))
        windows.append(none)
        HostedTestSupport.settle(0.05)
        XCTAssertNil(none.contentView.flatMap(Self.firstSearchField), "no controller: no bar mounted")
        let controller = openController()
        controller.open()
        let some = HostedTestSupport.host(
            MacChatFindSlot().environment(\.macChatFindController, controller).frame(width: 400, height: 60),
            size: NSSize(width: 400, height: 60)
        )
        windows.append(some)
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field != nil })
    }

    // MARK: window hosting

    func testTheWindowReaderRegistersTheControllerForItsWindow() {
        let controller = openController()
        let window = HostedTestSupport.host(
            Color.clear.background(MacChatFindWindowReader(controller: controller)).frame(width: 100, height: 100),
            size: NSSize(width: 100, height: 100)
        )
        windows.append(window)
        XCTAssertTrue(HostedTestSupport.waitUntil { MacChatFindControllers.controller(for: window) === controller })
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let found = firstSearchField(in: sub) { return found } }
        return nil
    }

    // MARK: hidden chat route

    private final class Route { var chat = true }

    private func routedController(_ route: Route) -> MacChatFindController {
        MacChatFindController(
            environment: .init(
                messages: { [] }, hasEarlierMessages: { false }, isTranscriptShown: { true },
                isChatRouteActive: { route.chat }
            ),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
    }

    func testSwitchingToAnotherTabClosesTheBarAndReleasesTheField() {
        let route = Route()
        let controller = routedController(route)
        let window = HostedTestSupport.host(MacChatFindBar(controller: controller).frame(width: 640, height: 60), size: NSSize(width: 640, height: 60))
        windows.append(window)
        controller.open()
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.ownsResponder(window.firstResponder) })
        route.chat = false   // Kanban
        controller.transcriptDidChange()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.ownsResponder(window.firstResponder), "the field no longer has focus")
        XCTAssertTrue(HostedTestSupport.waitUntil { controller.field == nil })
    }

    func testOpenDoesNothingWhileAnotherTabIsShown() {
        let route = Route()
        route.chat = false
        let controller = routedController(route)
        controller.open()
        XCTAssertFalse(controller.isOpen)
    }

    func testTheSidebarTabKeyClosesTheBarThroughTheRoutePublisher() async {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let controller = MacChatFindController(
            environment: .init(
                messages: { [] }, hasEarlierMessages: { false }, isTranscriptShown: { true },
                isChatRouteActive: { MacChatFindController.isChatRouteActive(defaults: suite.defaults) }
            ),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
        controller.observe(MacChatFindController.routeChanges(defaults: suite.defaults))
        controller.open()
        XCTAssertTrue(controller.isOpen)
        // Poll without blocking the main actor: the refresh hop is a main-actor task.
        func eventually(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !predicate() {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
        suite.defaults.set("unrelated", forKey: "other.key")   // not a route change
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.isOpen)
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let closed = await eventually { !controller.isOpen }
        XCTAssertTrue(closed)
    }

    // MARK: VoiceOver announcement policy

    func testOnlySettledResultsAreAnnouncedAndNotRepeated() async {
        let hits = [
            ChatMessage(id: "m1", role: .assistant, content: "needle", timestamp: ""),
            ChatMessage(id: "m2", role: .assistant, content: "needle", timestamp: ""),
        ]
        let controller = openController(hits: hits)
        var spoken: [String] = []
        controller.announce = { spoken.append($0) }
        controller.open()
        XCTAssertEqual(spoken, [], "opening with no query says nothing")
        controller.query = "n"
        controller.query = "ne"
        controller.query = "needle"   // the debounce coalesces the keystrokes
        await controller.settled()
        XCTAssertEqual(spoken, ["2 of 2"])
        controller.next()
        XCTAssertEqual(spoken, ["2 of 2", "1 of 2"])
        controller.query = "zzz"
        await controller.settled()
        XCTAssertEqual(spoken.last, "No matches")
        let count = spoken.count
        controller.query = "zzzz"   // another no-match query is new information
        await controller.settled()
        XCTAssertEqual(spoken.count, count + 1)
        controller.transcriptDidChange()   // a refresh never speaks
        await controller.settled()
        XCTAssertEqual(spoken.count, count + 1)
    }
}
