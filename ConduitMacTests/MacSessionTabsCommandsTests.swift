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
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window(identifier: "com_apple_SwiftUI_Settings_window")))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(nil))
    }

    func testCloseTabClosesTheActiveTabInTheChatWindow() {
        MacSessionTabsActions.closeTab(store: store, window: window(identifier: "conduit-primary-AppWindow-1"))
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(opened, ["b"])
    }

    func testCmdWInAnotherWindowClosesThatWindowNotATab() {
        let other = window(identifier: "com_apple_SwiftUI_Settings_window")
        other.orderFront(nil)
        MacSessionTabsActions.closeTab(store: store, window: other)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(HostedTestSupport.waitUntil { !other.isVisible })
    }

    func testCommandsDoNothingUnderASheet() {
        let main = window(identifier: "conduit-primary-AppWindow-1")
        let sheet = window(identifier: nil)
        main.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        MacSessionTabsActions.closeTab(store: store, window: main)
        MacSessionTabsActions.selectShortcut(1, store: store, window: main)
        MacSessionTabsActions.selectNeighbor(.next, store: store, window: main)
        MacSessionTabsActions.reopen(store: store, window: main)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(opened.isEmpty)
        main.endSheet(sheet)
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
