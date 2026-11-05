import AppKit
import XCTest
@testable import ConduitMac

/// A responder that sits outside the transcript, like the sidebar's list.
private final class SidebarStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class MacChatFindCommandsTests: XCTestCase {
    private struct Rig {
        let window: NSWindow
        let message: NSTextView
        let composer: ComposerTextView
        let sidebar: SidebarStandIn
        let controller: MacChatFindController
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var windows: [NSWindow] = []
    private var shown = true

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        shown = true
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        HostedTestSupport.dropSuite(suite)
    }

    private func rig(identifier: String = "conduit-primary-AppWindow-1") -> Rig {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let sidebar = SidebarStandIn(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 150, y: 100, width: 450, height: 300))
        let message = SelectableTextView.makeTextView()
        message.frame = NSRect(x: 0, y: 0, width: 450, height: 300)
        message.string = "hello needle"
        scroll.documentView = message
        let composer = ComposerTextView(frame: NSRect(x: 150, y: 0, width: 450, height: 80))
        [sidebar, scroll, composer].forEach(content.addSubview)
        window.orderFront(nil)
        windows.append(window)
        let messages = [ChatMessage(id: "m1", role: .assistant, content: "hello needle", timestamp: "")]
        let controller = MacChatFindController(
            environment: .init(messages: { messages }, hasEarlierMessages: { false }, isTranscriptShown: { [unowned self] in self.shown }),
            timing: .init(debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 1)
        )
        controller.registry.register(message, messageID: "m1")
        MacChatFindControllers.register(controller, in: window)
        return Rig(window: window, message: message, composer: composer, sidebar: sidebar, controller: controller)
    }

    private func find(_ rig: Rig) -> MacKeyboardActions.FindOutcome? {
        MacKeyboardActions.findOrSearchSessions(window: rig.window, defaults: suite.defaults, requests: MacFocusRequests())
    }

    // MARK: Cmd-F routing

    func testCmdFFromTheComposerOpensChatFind() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests), .chatFind)
        XCTAssertTrue(r.controller.isOpen)
        XCTAssertFalse(requests.searchPending, "Search Sessions was not asked")
    }

    func testCmdFFromAMessageViewOpensChatFindNotThePerMessageBar() {
        let r = rig()
        r.message.isSelectable = true
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        XCTAssertEqual(find(r), .chatFind)
        XCTAssertTrue(r.controller.isOpen)
        let scroll = r.message.enclosingScrollView
        XCTAssertEqual(scroll?.isFindBarVisible, false)
    }

    func testCmdFWithNothingFocusedOpensChatFind() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(nil))
        XCTAssertEqual(find(r), .chatFind)
    }

    func testCmdFFromTheSidebarStillSearchesSessions() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.sidebar))
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests), .searchSessions)
        XCTAssertTrue(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCmdFWhileChatIsHiddenSearchesSessions() {
        for tab in [SidebarTab.bots, .cron, .kanban, .home] {
            let r = rig()
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            XCTAssertTrue(r.window.makeFirstResponder(r.composer))
            XCTAssertEqual(find(r), .searchSessions, "\(tab)")
            XCTAssertFalse(r.controller.isOpen, "\(tab)")
        }
    }

    func testCmdFInAGroupRoomSearchesSessions() {
        let r = rig()
        shown = false
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        XCTAssertEqual(find(r), .searchSessions)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCmdFWhileOpenRefocusesAndKeepsTheFirstRestoreTarget() {
        let r = rig()
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        XCTAssertEqual(find(r), .chatFind)
        let token = r.controller.focusToken
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        XCTAssertEqual(find(r), .chatFind)
        XCTAssertGreaterThan(r.controller.focusToken, token)
        r.controller.close()
        XCTAssertTrue(r.window.firstResponder === r.message, "focus went back to where the first Cmd-F started")
    }

    func testCmdFWithNoControllerKeepsTheD10Behaviour() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let composer = ComposerTextView()
        window.contentView?.addSubview(composer)
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()), .searchSessions)
    }

    // MARK: guards

    func testSessionWindowComposerFindDoesNothing() {
        let r = rig(identifier: "conduit-session-AppWindow-2")
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        let requests = MacFocusRequests()
        XCTAssertNil(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests))
        XCTAssertFalse(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        MacChatFindActions.previous(window: r.window, defaults: suite.defaults)
        MacKeyboardActions.searchSessions(window: r.window, defaults: suite.defaults, requests: requests)
        XCTAssertFalse(r.controller.isOpen)
        XCTAssertFalse(requests.searchPending)
        XCTAssertTrue(MacSessionWindows.isSessionWindow(r.window))
        XCTAssertFalse(MacSessionWindows.isSessionWindow(rig().window))
        XCTAssertFalse(MacSessionWindows.isSessionWindow(nil))
    }

    /// Controller ruling: a session window keeps the pre-D23 behaviour, the
    /// focused message view's own find bar through the responder chain.
    func testSessionWindowFocusedMessageKeepsItsOwnFindBar() {
        let r = rig(identifier: "conduit-session-AppWindow-2")
        r.message.isSelectable = true
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: requests), .messageFind)
        XCTAssertEqual(r.message.enclosingScrollView?.isFindBarVisible, true, "the message view's own bar opened")
        XCTAssertFalse(r.controller.isOpen, "never the whole-chat bar")
        XCTAssertFalse(requests.searchPending)
    }

    func testSessionWindowFindActionsNeedAFocusedMessageView() {
        let r = rig(identifier: "conduit-session-AppWindow-2")
        r.message.isSelectable = true
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        XCTAssertTrue(MacChatFindActions.sessionWindowFind(.showFindInterface, window: r.window))
        // The bar's field now holds focus; Cmd-G and Cmd-Shift-G still reach the message view.
        for action in [NSTextFinder.Action.nextMatch, .previousMatch] {
            XCTAssertTrue(MacChatFindActions.sessionWindowFind(action, window: r.window), "\(action)")
        }
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        MacChatFindActions.previous(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
        XCTAssertTrue(r.window.makeFirstResponder(r.composer))
        XCTAssertFalse(MacChatFindActions.sessionWindowFind(.nextMatch, window: r.window))
        XCTAssertFalse(MacChatFindActions.sessionWindowFind(.nextMatch, window: nil))
    }

    func testSessionWindowFindStillBlockedBySheet() {
        let r = rig(identifier: "conduit-session-AppWindow-2")
        r.message.isSelectable = true
        XCTAssertTrue(r.window.makeFirstResponder(r.message))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        r.window.beginSheet(sheet)
        defer { r.window.endSheet(sheet) }
        XCTAssertNil(MacKeyboardActions.findOrSearchSessions(window: r.window, defaults: suite.defaults, requests: MacFocusRequests()))
        XCTAssertEqual(r.message.enclosingScrollView?.isFindBarVisible, false)
    }

    func testASheetBlocksEveryFindCommand() {
        let r = rig()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        r.window.beginSheet(sheet)
        defer { r.window.endSheet(sheet) }
        XCTAssertNil(find(r))
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
    }

    func testCommandsWithoutAWindowDoNothing() {
        XCTAssertEqual(
            MacKeyboardActions.findOrSearchSessions(window: nil, defaults: suite.defaults, requests: MacFocusRequests()),
            .searchSessions,
            "no window: D10's Search Sessions, never a chat find"
        )
        MacChatFindActions.next(window: nil, defaults: suite.defaults)
        MacChatFindActions.previous(window: nil, defaults: suite.defaults)
    }

    // MARK: Cmd-G / Cmd-Shift-G

    func testCmdGOpensTheBarWhenClosedAndStepsWhenOpen() async {
        let r = rig()
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertTrue(r.controller.isOpen, "Cmd-G with the bar closed opens it")
        r.controller.query = "needle"
        await r.controller.settled()
        XCTAssertEqual(r.controller.state.position, 1)
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertEqual(r.controller.state.position, 1, "one hit: wraps to itself")
        MacChatFindActions.previous(window: r.window, defaults: suite.defaults)
        XCTAssertEqual(r.controller.state.position, 1)
    }

    func testCmdGStepsFromAnyFocusWhileOpen() async {
        let r = rig()
        r.controller.open()
        r.controller.query = "needle"
        await r.controller.settled()
        XCTAssertTrue(r.window.makeFirstResponder(r.sidebar))
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertTrue(r.controller.isOpen)
    }

    func testCmdGWhileChatIsHiddenOrInARoomDoesNothing() {
        let r = rig()
        for tab in [SidebarTab.kanban, .home] {
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            MacChatFindActions.next(window: r.window, defaults: suite.defaults)
            XCTAssertFalse(r.controller.isOpen, "\(tab)")
        }
        suite.defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        shown = false
        MacChatFindActions.next(window: r.window, defaults: suite.defaults)
        XCTAssertFalse(r.controller.isOpen)
    }

    // MARK: Search Sessions item

    func testSearchSessionsMenuActionFocusesTheSearchWithoutTouchingFind() {
        let r = rig()
        let requests = MacFocusRequests()
        MacKeyboardActions.searchSessions(window: r.window, defaults: suite.defaults, requests: requests)
        XCTAssertTrue(requests.searchPending)
        XCTAssertFalse(r.controller.isOpen)
    }
}
