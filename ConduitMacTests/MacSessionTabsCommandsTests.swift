import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabsCommandsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacSessionTabsStore!
    private var opened: [String] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        opened = []
        store.openSession = { [unowned self] in self.opened.append($0) }
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func window(identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        windows.append(w)
        return w
    }

    func testMainChatWindowIsTheConduitPrimaryWindowGroup() {
        XCTAssertTrue(MacSessionTabsActions.isMainChatWindow(window(identifier: "conduit-primary-AppWindow-1")))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window(identifier: "auxiliary-window")))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(nil))
    }

    func testCloseTabClosesTheActiveTabInTheChatWindow() {
        MacSessionTabsActions.closeTab(store: store, window: window(identifier: "conduit-primary-AppWindow-1"))
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(opened, ["b"])
    }

    func testCmdWInAnAuxiliaryWindowClosesThatWindowNotATab() {
        let other = window(identifier: "auxiliary-window")
        other.orderFront(nil)
        MacSessionTabsActions.closeTab(store: store, window: other)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(HostedTestSupport.waitUntil { !other.isVisible })
    }

    func testCommandsDoNothingUnderASheet() {
        let main = window(identifier: "conduit-primary-AppWindow-1")
        let sheet = window(identifier: nil)
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        MacSessionTabsActions.closeTab(store: store, window: main)
        MacSessionTabsActions.selectShortcut(1, store: store, window: main)
        MacSessionTabsActions.selectNeighbor(.next, store: store, window: main)
        MacSessionTabsActions.reopen(store: store, window: main)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(opened.isEmpty)
    }

    func testCmdWInASheetDoesNothing() {
        let main = window(identifier: "conduit-primary-AppWindow-1")
        main.orderFront(nil)
        let sheet = window(identifier: "auxiliary-window")
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { sheet.sheetParent != nil })
        MacSessionTabsActions.closeTab(store: store, window: sheet)
        // A bounded wait is the only way to prove "nothing happened" (a deliberate fixed delay).
        HostedTestSupport.settle(0.3)
        XCTAssertTrue(sheet.sheetParent === main, "still attached")
        XCTAssertTrue(sheet.isVisible)
        XCTAssertEqual(store.model.tabs.count, 3)
    }

    func testCmdWWithNoTabsDoesNothing() {
        let empty = MacSessionTabsStore(defaults: suite.defaults)
        empty.setScope(dashboardID: UUID(), profile: "empty")
        var newChats = 0
        empty.startNewChat = { newChats += 1 }
        MacSessionTabsActions.closeTab(store: empty, window: window(identifier: "conduit-primary-AppWindow-1"))
        XCTAssertTrue(empty.model.tabs.isEmpty)
        XCTAssertEqual(newChats, 0)
    }

    func testOtherCommandsDoNothingForNoWindowOrANonChatWindow() {
        let other = window(identifier: "auxiliary-window")
        for target in [nil, other] {
            MacSessionTabsActions.reopen(store: store, window: target)
            MacSessionTabsActions.selectShortcut(1, store: store, window: target)
            MacSessionTabsActions.selectNeighbor(.previous, store: store, window: target)
            MacSessionTabsActions.closeTab(store: store, window: nil)
        }
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(opened.isEmpty)
    }

    func testPanesMovedToControlCommand() {
        for shortcut in MacSidebarShortcut.allCases {
            XCTAssertEqual(shortcut.modifiers, [.control, .command])
        }
    }

    func testComposerLeavesControlTabToTheMenu() {
        let composer = ComposerTextView()
        let w = window(identifier: nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        content.addSubview(composer)
        w.contentView = content
        w.orderFront(nil)
        XCTAssertTrue(w.makeFirstResponder(composer))
        for (flags, chars) in [(NSEvent.ModifierFlags.control, "\t"), ([.control, .shift], "\t")] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: w.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 48)!
            XCTAssertFalse(composer.performKeyEquivalent(with: event))
        }
    }
}
