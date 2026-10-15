import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

// Keyboard support (D10): shortcut table, previous / next ordering, the list
// cursor, Cmd-F / Cmd-L, and Tab traversal. Pure logic first, then the real
// menu, then hosted views driven with synthetic key events. Hosted tests use
// injected defaults suites and notification centres (see HostedTestSupport);
// none of them fires a real menu item, which would write the live app's
// defaults.

final class MacSidebarShortcutTests: XCTestCase {
    func testDigitsMapToTabsInTabStripOrder() {
        XCTAssertEqual(MacSidebarShortcut.tab(forKey: "1"), .sessions)
        XCTAssertEqual(MacSidebarShortcut.tab(forKey: "2"), .bots)
        XCTAssertEqual(MacSidebarShortcut.tab(forKey: "3"), .cron)
        XCTAssertEqual(MacSidebarShortcut.tab(forKey: "4"), .kanban)
    }

    func testOtherKeysMapToNothing() {
        for key in ["0", "5", "9", "a", "[", " "] as [Character] {
            XCTAssertNil(MacSidebarShortcut.tab(forKey: key), "\(key)")
        }
    }

    func testEveryTabHasExactlyOneDistinctShortcut() {
        let tabs = MacSidebarShortcut.allCases.map(\.tab)
        XCTAssertEqual(Set(tabs), Set(SidebarTab.allCases), "a new tab needs a shortcut")
        XCTAssertEqual(tabs.count, SidebarTab.allCases.count)
        let keys = MacSidebarShortcut.allCases.map(\.key.character)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(tabs, SidebarTab.allCases, "numbered in tab-strip order")
    }

    func testTitleIsTheTabsOwnName() {
        for shortcut in MacSidebarShortcut.allCases {
            XCTAssertEqual(shortcut.title, shortcut.tab.displayName)
        }
    }
}

final class MacSessionNavigationTests: XCTestCase {
    private let ids = ["a", "b", "c"]

    func testStepsThroughTheMiddle() {
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "b", in: ids, direction: .previous), "a")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "b", in: ids, direction: .next), "c")
    }

    func testNoopAtTheEnds() {
        XCTAssertNil(MacSessionNavigation.neighbor(of: "a", in: ids, direction: .previous))
        XCTAssertNil(MacSessionNavigation.neighbor(of: "c", in: ids, direction: .next))
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "a", in: ids, direction: .next), "b")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "c", in: ids, direction: .previous), "b")
    }

    func testEmptyListHasNoNeighbor() {
        XCTAssertNil(MacSessionNavigation.neighbor(of: "a", in: [], direction: .next))
        XCTAssertNil(MacSessionNavigation.neighbor(of: nil, in: [], direction: .previous))
    }

    func testSingleSessionHasNoNeighbor() {
        XCTAssertNil(MacSessionNavigation.neighbor(of: "a", in: ["a"], direction: .next))
        XCTAssertNil(MacSessionNavigation.neighbor(of: "a", in: ["a"], direction: .previous))
    }

    func testActiveSessionNotListedEntersAtTheNearEnd() {
        // Hidden by the search or a filter: next goes to the top, previous to the bottom.
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "zzz", in: ids, direction: .next), "a")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "zzz", in: ids, direction: .previous), "c")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: nil, in: ids, direction: .next), "a")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: nil, in: ids, direction: .previous), "c")
    }

    func testFollowsTheGivenOrderNotAlphabeticalOrder() {
        let shown = ["pinned-z", "pinned-a", "recent-m"]
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "pinned-z", in: shown, direction: .next), "pinned-a")
        XCTAssertEqual(MacSessionNavigation.neighbor(of: "recent-m", in: shown, direction: .previous), "pinned-a")
    }
}

final class MacSessionCursorTests: XCTestCase {
    private let ids = ["a", "b", "c"]

    func testDownAndUpStopAtTheEnds() {
        XCTAssertEqual(MacSessionCursor.moved(.down, from: "a", in: ids), "b")
        XCTAssertEqual(MacSessionCursor.moved(.down, from: "c", in: ids), "c")
        XCTAssertEqual(MacSessionCursor.moved(.up, from: "c", in: ids), "b")
        XCTAssertEqual(MacSessionCursor.moved(.up, from: "a", in: ids), "a")
    }

    func testNoBaseDownPicksFirstAndUpPicksLast() {
        XCTAssertEqual(MacSessionCursor.moved(.down, from: nil, in: ids), "a")
        XCTAssertEqual(MacSessionCursor.moved(.up, from: nil, in: ids), "c")
        XCTAssertEqual(MacSessionCursor.moved(.down, from: "gone", in: ids), "a")
        XCTAssertEqual(MacSessionCursor.moved(.up, from: "gone", in: ids), "c")
    }

    func testHomeAndEnd() {
        XCTAssertEqual(MacSessionCursor.moved(.first, from: "b", in: ids), "a")
        XCTAssertEqual(MacSessionCursor.moved(.last, from: "b", in: ids), "c")
    }

    func testEmptyList() {
        for move in [MacSessionCursor.Move.up, .down, .first, .last] {
            XCTAssertNil(MacSessionCursor.moved(move, from: "a", in: []), "\(move)")
        }
    }

    func testOnlyKeyboardFocusShowsTheCursorAtOnce() {
        XCTAssertTrue(MacSessionCursor.showsOnFocus(.keyDown))
        XCTAssertFalse(MacSessionCursor.showsOnFocus(.leftMouseDown))
        XCTAssertFalse(MacSessionCursor.showsOnFocus(nil))
    }

    func testCursorSurvivesOnlyWhileItsRowIsListed() {
        XCTAssertEqual(MacSessionCursor.reconciled("b", in: ids), "b")
        XCTAssertNil(MacSessionCursor.reconciled("b", in: ["a", "c"]))
        XCTAssertNil(MacSessionCursor.reconciled(nil, in: ids))
    }
}

@MainActor
final class MacKeyboardActionsTests: XCTestCase {
    func testSelectTabWritesTheRoutingKey() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        for shortcut in MacSidebarShortcut.allCases {
            MacKeyboardActions.selectTab(shortcut.tab, defaults: suite.defaults)
            XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), shortcut.tab.rawValue)
            XCTAssertEqual(MacChatRoute.isChatActive(tabRaw: suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey)),
                           shortcut == .sessions)
        }
    }

    func testSearchShowsAHiddenSidebarAndLeavesTheTabAlone() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(false, forKey: MacSidebarState.defaultsKey)
        suite.defaults.set(SidebarTab.cron.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let requests = MacFocusRequests()
        MacKeyboardActions.focusSessionSearch(defaults: suite.defaults, requests: requests)
        XCTAssertTrue(suite.defaults.bool(forKey: MacSidebarState.defaultsKey))
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.cron.rawValue,
                       "the sidebar lists sessions whatever the main pane shows (D6)")
        XCTAssertTrue(requests.searchPending)
        XCTAssertEqual(requests.searchToken, 1)
    }

    func testSearchRequestIsConsumedOnce() {
        let requests = MacFocusRequests()
        XCTAssertFalse(requests.consumeSearch())
        requests.requestSearch()
        XCTAssertTrue(requests.consumeSearch())
        XCTAssertFalse(requests.consumeSearch())
    }

    func testSearchRequestExpiresIfNoListMountsSoon() {
        let requests = MacFocusRequests()
        let start = Date()
        requests.requestSearch(now: start)
        XCTAssertFalse(requests.consumeSearch(now: start.addingTimeInterval(MacFocusRequests.pendingLifetime + 0.5)),
                       "a list that mounts after login must not take the keyboard")
        requests.requestSearch(now: start)
        XCTAssertTrue(requests.consumeSearch(now: start.addingTimeInterval(MacFocusRequests.pendingLifetime - 0.1)))
    }

    func testAnotherFocusActionCancelsAPendingSearch() {
        let requests = MacFocusRequests()
        requests.requestSearch()
        let token = requests.searchToken
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        MacKeyboardActions.focusComposer(window: window, defaults: suite.defaults, center: NotificationCenter(), requests: requests)
        XCTAssertFalse(requests.consumeSearch(), "Cmd-L after Cmd-F wins")
        XCTAssertNotEqual(requests.searchToken, token, "and any retry in flight stops")
    }

    // MARK: Retry

    private func retryWindow() -> (window: NSWindow, field: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        // A text field (the window's initial responder, sharing the field
        // editor) and a composer standing in for "somewhere else".
        let first = NSTextField(frame: NSRect(x: 10, y: 50, width: 100, height: 24))
        let field = ComposerTextView()
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 24)
        content.addSubview(first)
        content.addSubview(field)
        window.contentView = content
        window.orderFront(nil)
        return (window, field)
    }

    func testRetryKeepsTryingUntilTheAttemptLands() {
        let requests = MacFocusRequests()
        let (window, _) = retryWindow()
        defer { window.close() }
        var attempts = 0
        requests.retrySearchFocus(in: window, interval: 0.01, maxAttempts: 20) { attempts += 1 }
        XCTAssertEqual(attempts, 1, "the first attempt is immediate")
        XCTAssertTrue(HostedTestSupport.waitUntil { attempts >= 4 }, "retried while nothing took the keyboard")
    }

    func testRetryStopsOnceTheKeyboardMovedElsewhere() {
        let requests = MacFocusRequests()
        let (window, field) = retryWindow()
        defer { window.close() }
        var attempts = 0
        requests.retrySearchFocus(in: window, interval: 0.01, maxAttempts: 50) { attempts += 1 }
        XCTAssertTrue(HostedTestSupport.waitUntil { attempts >= 2 })
        XCTAssertTrue(window.makeFirstResponder(field))   // a click, or Cmd-L, took the keyboard
        HostedTestSupport.settle(0.05)
        let frozen = attempts
        HostedTestSupport.settle(0.15)
        XCTAssertEqual(attempts, frozen, "a late retry never pulls focus back")
    }

    func testRetryStopsWhenSupersededByAnotherRequest() {
        let requests = MacFocusRequests()
        let (window, _) = retryWindow()
        defer { window.close() }
        var attempts = 0
        requests.retrySearchFocus(in: window, interval: 0.01, maxAttempts: 50) { attempts += 1 }
        XCTAssertTrue(HostedTestSupport.waitUntil { attempts >= 2 })
        requests.cancelSearch()
        HostedTestSupport.settle(0.05)
        let frozen = attempts
        HostedTestSupport.settle(0.15)
        XCTAssertEqual(attempts, frozen)
    }

    func testRetryIsBounded() {
        let requests = MacFocusRequests()
        let (window, _) = retryWindow()
        defer { window.close() }
        var attempts = 0
        requests.retrySearchFocus(in: window, interval: 0.005, maxAttempts: 3) { attempts += 1 }
        XCTAssertTrue(HostedTestSupport.waitUntil { attempts >= 4 })
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(attempts, 4, "one immediate attempt plus at most three retries")
    }

    // MARK: Cmd-F contextual

    private func findWindow(textView: NSTextView) -> (NSWindow, NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        textView.string = "hello find"
        scroll.documentView = textView
        window.contentView = scroll
        window.orderFront(nil)
        return (window, scroll)
    }

    func testCmdFOpensTheFindBarOfAFocusedMessageView() {
        let message = NSTextView()
        message.isSelectable = true
        message.usesFindBar = true   // as SelectableTextView does
        let (window, scroll) = findWindow(textView: message)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(message))
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let requests = MacFocusRequests()
        let outcome = MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: requests)
        XCTAssertEqual(outcome, .messageFind)
        XCTAssertTrue(HostedTestSupport.waitUntil { scroll.isFindBarVisible }, "the message view's own find bar opened")
        XCTAssertFalse(requests.searchPending, "Search Sessions was not asked")
    }

    func testCmdFGoesToSearchSessionsWhenChatIsNotTheShownPane() {
        // The hidden chat (opacity 0, not AppKit-hidden) can keep a message
        // view as first responder under Cron / Kanban.
        for tab in [SidebarTab.bots, .cron, .kanban] {
            let message = NSTextView()
            message.isSelectable = true
            message.usesFindBar = true
            let (window, scroll) = findWindow(textView: message)
            defer { window.close() }
            XCTAssertTrue(window.makeFirstResponder(message))
            let suite = HostedTestSupport.makeSuite()
            defer { HostedTestSupport.dropSuite(suite) }
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            let requests = MacFocusRequests()
            XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: requests),
                           .searchSessions, "\(tab)")
            XCTAssertTrue(requests.searchPending, "\(tab)")
            XCTAssertFalse(scroll.isFindBarVisible, "\(tab): no find bar in the hidden chat")
        }
    }

    func testCmdFGoesToSearchSessionsWhenTheMessageViewIsNotOnScreen() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let message = NSTextView()
        message.isSelectable = true
        message.usesFindBar = true
        let (window, scroll) = findWindow(textView: message)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(message))
        scroll.isHidden = true
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()),
                       .searchSessions, "hidden ancestor")
        scroll.isHidden = false
        window.orderOut(nil)
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()),
                       .searchSessions, "window not visible")
        window.orderFront(nil)
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()),
                       .messageFind, "and back on screen it finds again")
    }

    func testCmdFFocusesSearchSessionsFromTheComposer() {
        let composer = ComposerTextView()
        let (window, scroll) = findWindow(textView: composer)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let requests = MacFocusRequests()
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: requests), .searchSessions)
        XCTAssertTrue(requests.searchPending)
        XCTAssertFalse(scroll.isFindBarVisible)
    }

    func testCmdFFocusesSearchSessionsWhenNothingIsFocusedOrTheViewCannotFind() {
        let plain = NSTextView()   // usesFindBar false: not a message view
        let (window, _) = findWindow(textView: plain)
        defer { window.close() }
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        XCTAssertTrue(window.makeFirstResponder(plain))
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: window, defaults: suite.defaults, requests: MacFocusRequests()), .searchSessions)
        XCTAssertNil(MacKeyboardActions.findTarget(in: nil))
        XCTAssertEqual(MacKeyboardActions.findOrSearchSessions(window: nil, defaults: suite.defaults, requests: MacFocusRequests()), .searchSessions)
    }

    // MARK: Sheets and windows

    func testCommandsDoNothingWhileASheetIsAttachedOrIsTheKeyWindow() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { parent.close(); sheet.close() }
        parent.orderFront(nil)
        XCTAssertFalse(MacKeyboardActions.commandsBlocked(by: parent))
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }
        XCTAssertTrue(MacKeyboardActions.commandsBlocked(by: parent), "sheet attached")
        XCTAssertTrue(MacKeyboardActions.commandsBlocked(by: sheet), "the sheet itself is the key window")
        XCTAssertFalse(MacKeyboardActions.commandsBlocked(by: nil))

        let requests = MacFocusRequests()
        MacKeyboardActions.selectTab(.kanban, window: parent, defaults: suite.defaults)
        XCTAssertNil(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey))
        XCTAssertNil(MacKeyboardActions.findOrSearchSessions(window: parent, defaults: suite.defaults, requests: requests))
        XCTAssertFalse(requests.searchPending)
        var opened: [String] = []
        MacKeyboardActions.openNeighbor(.next, order: ["a", "b"], activeID: "a", window: parent) { opened.append($0) }
        XCTAssertTrue(opened.isEmpty)
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        MacKeyboardActions.focusComposer(window: parent, defaults: suite.defaults, center: center, requests: requests)
        XCTAssertEqual(posts, 0)
    }

    func testComposerFocusWithNoWindowReachesNoComposer() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        MacKeyboardActions.focusComposer(window: nil, defaults: suite.defaults, center: center)
        XCTAssertEqual(posts, 0, "an unaddressed request would reach every composer")
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
    }

    func testComposerFocusReturnsToChatAndNamesTheWindow() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let center = NotificationCenter()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var posted: [Notification] = []
        let token = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: nil) { posted.append($0) }
        defer { center.removeObserver(token) }
        MacKeyboardActions.focusComposer(window: window, defaults: suite.defaults, center: center)
        XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.sessions.rawValue)
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted.first?.object as? NSWindow === window)
    }

    func testOpenNeighborUsesTheRowClickPathOnlyWhenThereIsAStep() {
        var opened: [String] = []
        let order = ["a", "b", "c"]
        MacKeyboardActions.openNeighbor(.next, order: order, activeID: "a") { opened.append($0) }
        MacKeyboardActions.openNeighbor(.previous, order: order, activeID: "b") { opened.append($0) }
        XCTAssertEqual(opened, ["b", "a"])
        MacKeyboardActions.openNeighbor(.next, order: order, activeID: "c") { opened.append($0) }
        MacKeyboardActions.openNeighbor(.previous, order: order, activeID: "a") { opened.append($0) }
        MacKeyboardActions.openNeighbor(.next, order: nil, activeID: "a") { opened.append($0) }
        MacKeyboardActions.openNeighbor(.next, order: [], activeID: nil) { opened.append($0) }
        XCTAssertEqual(opened, ["b", "a"], "ends, no list and an empty list are no-ops")
    }
}

// MARK: - The real menu

@MainActor
final class MacKeyboardMenuTests: XCTestCase {
    private struct Entry {
        let path: String
        let item: NSMenuItem
    }

    /// Depth-first, in the order AppKit searches for key equivalents.
    private func entries(_ menu: NSMenu, path: String = "") -> [Entry] {
        menu.items.flatMap { item -> [Entry] in
            let here = path + "/" + item.title
            return [Entry(path: here, item: item)] + (item.submenu.map { entries($0, path: here) } ?? [])
        }
    }

    private func matches(_ entry: Entry, key: String, mask: NSEvent.ModifierFlags) -> Bool {
        entry.item.keyEquivalent == key
            && entry.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mask
    }

    private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func shortcuts() -> [(path: String, key: String, mask: NSEvent.ModifierFlags)] {
        var table: [(String, String, NSEvent.ModifierFlags)] = MacSidebarShortcut.allCases.map { shortcut in
            ("/Go/\(shortcut.title)", String(shortcut.key.character), [.control, .command])
        }
        table += (1...8).map { ("/Go/Tab \($0)", "\($0)", NSEvent.ModifierFlags.command) }
        table += [
            ("/Go/Last Tab", "9", .command),
            // AppKit reports Cmd-Shift-] as "]" with [.shift, .command] (observed).
            ("/Go/Next Tab", "]", [.shift, .command]),
            ("/Go/Previous Tab", "[", [.shift, .command]),
            ("/Go/Show Next Tab", "\t", .control),
            ("/Go/Show Previous Tab", "\t", [.control, .shift]),
            ("/File/Close Tab", "w", .command),
            ("/File/Reopen Closed Tab", "t", [.shift, .command]),
            ("/Chat/Ask About Window\u{2026}", "w", [.shift, .command]),
        ]
        table += [
            ("/Go/Previous Session", "[", .command),
            ("/Go/Next Session", "]", .command),
            ("/Go/Session Above", up, [.option, .command]),
            ("/Go/Session Below", down, [.option, .command]),
            ("/Go/Message Field", "l", .command),
            ("/Edit/Search Sessions", "f", .command),
        ]
        return table
    }

    func testEveryShortcutIsInTheMenuAndWinsItsKey() throws {
        let main = try XCTUnwrap(NSApp.mainMenu, "SwiftUI has not built the main menu")
        let all = entries(main)
        for expected in shortcuts() {
            let first = all.first { matches($0, key: expected.key, mask: expected.mask) }
            XCTAssertEqual(first?.path, expected.path,
                           "AppKit stops at the first item with this key equivalent, even a disabled one")
        }
    }

    func testOurShortcutsAreUnique() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let all = entries(main)
        for expected in shortcuts() where expected.key != "f" {
            let found = all.filter { matches($0, key: expected.key, mask: expected.mask) }
            XCTAssertEqual(found.map(\.path), [expected.path], "no other item may share \(expected.path)'s shortcut")
        }
    }

    func testFindItemStaysInTheMenuWithoutCmdF() throws {
        // Edit > Find > Find... would otherwise claim Cmd-F too. Print the
        // state so a SwiftUI change in how it resolves the clash is visible.
        let main = try XCTUnwrap(NSApp.mainMenu)
        let all = entries(main)
        let find = try XCTUnwrap(all.first { $0.path == "/Edit/Find/Find\u{2026}" }, "per-message find stays reachable from the menu")
        let cmdF = all.filter { matches($0, key: "f", mask: .command) }.map(\.path)
        XCTAssertEqual(cmdF.first, "/Edit/Search Sessions")
        XCTAssertEqual(cmdF.count, 1, "Cmd-F belongs to one item (Find is '\(find.item.keyEquivalent)'): \(cmdF)")
    }

    func testSidebarToggleShortcutIsUntouched() throws {
        let main = try XCTUnwrap(NSApp.mainMenu)
        let found = entries(main).filter { matches($0, key: "s", mask: [.command, .control]) }
        XCTAssertEqual(found.count, 1)
    }

    /// Ctrl-Cmd-S end to end against injected defaults: the toggle action
    /// writes the key, and a hosted `MacSplitLayout` reading that same suite
    /// collapses and reopens its sidebar column.
    func testSidebarToggleActionDrivesTheSplitLayout() throws {
        XCTAssertEqual(ConduitCommands.sidebarVisibleKey, MacSidebarState.defaultsKey)
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MacSplitLayout(
            defaults: suite.defaults, sidebar: { List { Text("sidebar row") } }, chat: { Text("chat") })
            .environmentObject(AppStateRuntimeRegistry.shared.appState))
        window.setContentSize(NSSize(width: 1000, height: 500))
        window.orderFront(nil)
        defer { HostedTestSupport.tearDown(window) }

        /// The sidebar list is on screen: its column wrapper is not hidden.
        func sidebarShown() -> Bool {
            func list(_ view: NSView) -> NSView? {
                if view is NSTableView { return view }
                for sub in view.subviews { if let found = list(sub) { return found } }
                return nil
            }
            guard let content = window.contentView, let table = list(content) else { return false }
            return !table.isHiddenOrHasHiddenAncestor
        }
        XCTAssertTrue(HostedTestSupport.waitUntil { sidebarShown() }, "sidebar shown by default")
        MacSidebarState.toggleVisible(defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.object(forKey: MacSidebarState.defaultsKey) as? Bool, false)
        XCTAssertTrue(HostedTestSupport.waitUntil { !sidebarShown() }, "the layout hid the sidebar")
        MacSidebarState.toggleVisible(defaults: suite.defaults)
        XCTAssertTrue(HostedTestSupport.waitUntil { sidebarShown() }, "and showed it again")
    }

    func testToggleReadsAMissingKeyAsShown() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        MacSidebarState.toggleVisible(defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.object(forKey: MacSidebarState.defaultsKey) as? Bool, false)
    }

    func testComposerDoesNotSwallowAnyOfTheShortcuts() {
        let composer = ComposerTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        composer.frame = NSRect(x: 10, y: 10, width: 200, height: 40)
        content.addSubview(composer)
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        for expected in shortcuts() {
            let arrow = expected.key == up || expected.key == down
            let flags = expected.mask.union(arrow ? [.numericPad, .function] : [])
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: expected.key,
                charactersIgnoringModifiers: expected.key, isARepeat: false, keyCode: 0)!
            XCTAssertFalse(composer.performKeyEquivalent(with: event),
                           "the text view must leave \(expected.path) to the menu")
            XCTAssertFalse(window.performKeyEquivalent(with: event), expected.path)
        }
        XCTAssertEqual(composer.string, "")
    }

    func testComposerHasNoFindOfItsOwnToStealCmdF() {
        let composer = ComposerTextView()
        XCTAssertFalse(composer.usesFindPanel)
        XCTAssertFalse(composer.usesFindBar)
    }
}

// MARK: - Hosted: sidebar list cursor, search focus, Tab traversal

@MainActor
final class MacSessionListKeyboardTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var ids = ["a", "b", "c", "d"]
        @Published var activeID: String? = "b"
        @Published var opened: [String] = []
        @Published var clicked: [String] = []
        @Published var search = ""
    }

    /// The same modifier chain SessionList uses: row cursor ring on each
    /// row, the keyboard modifier on the List after `.searchable`.
    struct Probe: View {
        @ObservedObject var model: Model
        let requests: MacFocusRequests
        var body: some View {
            NavigationSplitView {
                List {
                    ForEach(model.ids, id: \.self) { id in
                        Button { model.clicked.append(id) } label: {
                            Text(id)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .modifier(MacSessionCursorRow(id: id))
                    }
                }
                .searchable(text: $model.search, prompt: "Search sessions")
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .modifier(MacSessionListKeyboard(
                    ids: model.ids, activeID: model.activeID,
                    open: { model.opened.append($0) }, requests: requests))
            } detail: {
                Text("detail")
            }
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        super.tearDown()
    }

    private func host(_ model: Model, requests: MacFocusRequests? = nil) -> NSWindow {
        let requests = requests ?? MacFocusRequests()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                         styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: Probe(model: model, requests: requests))
        w.setContentSize(NSSize(width: 900, height: 500))
        w.orderFront(nil)
        window = w
        return w
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for sub in view.subviews { found += find(type, in: sub) }
        return found
    }

    private func table(in window: NSWindow) -> NSTableView? { find(NSTableView.self, in: window.contentView!).first }

    private func waitForTable(in window: NSWindow) throws -> NSTableView {
        var found: NSTableView?
        XCTAssertTrue(HostedTestSupport.waitUntil { found = self.table(in: window); return (found?.numberOfRows ?? 0) > 0 })
        return try XCTUnwrap(found)
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func pressDown(_ window: NSWindow) { window.sendEvent(key("\u{F701}", 125, arrowFlags, in: window)) }
    private func pressUp(_ window: NSWindow) { window.sendEvent(key("\u{F700}", 126, arrowFlags, in: window)) }
    private func pressReturn(_ window: NSWindow) { window.sendEvent(key("\r", 36, in: window)) }

    /// Focuses the list and lets SwiftUI see the focus (the cursor follows it).
    private func focusList(_ table: NSTableView, in window: NSWindow) {
        XCTAssertTrue(window.makeFirstResponder(table))
        HostedTestSupport.settle(0.15)
    }

    // MARK: Behaviour

    func testDownMovesFromTheOpenSessionAndReturnOpensTheCursorRow() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        pressDown(window)   // open session is "b": cursor lands on "c"
        pressReturn(window)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.opened == ["c"] }, "opened: \(model.opened)")
        XCTAssertTrue(model.clicked.isEmpty, "keyboard open is not a click")
    }

    func testUpDownStopAtTheEndsAndReturnOpensWhereTheCursorIs() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        for _ in 0..<5 { pressDown(window) }
        pressReturn(window)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.opened == ["d"] }, "stops at the last row: \(model.opened)")
        for _ in 0..<6 { pressUp(window) }
        pressReturn(window)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.opened == ["d", "a"] }, "stops at the first row: \(model.opened)")
    }

    func testReturnWithoutACursorOpensNothing() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        pressReturn(window)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(model.opened.isEmpty)
    }

    func testModifiedArrowsAreLeftAlone() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        for flags: NSEvent.ModifierFlags in [[.shift], [.option], [.command], [.control]] {
            window.sendEvent(key("\u{F701}", 125, arrowFlags.union(flags), in: window))
        }
        pressReturn(window)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(model.opened.isEmpty, "Shift / Option / Command / Control arrows must not move the cursor")
    }

    func testCursorFollowsTheVisibleRowsNotAStaleOne() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        pressDown(window)   // c
        model.ids = ["a", "b", "d"]   // search removed "c"
        HostedTestSupport.settle(0.3)
        pressReturn(window)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(model.opened.isEmpty, "a cursor on a row that left the list is dropped")
    }

    func testClickStillReachesTheRowButton() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        // A click is routed by AppKit to the row's hosted view; the cursor
        // ring overlay must not intercept it (it has hit testing off).
        focusList(table, in: window)
        pressDown(window)
        HostedTestSupport.settle(0.2)
        let rect = table.convert(table.rect(ofRow: 2), to: nil)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        window.sendEvent(down)
        window.sendEvent(up)
        XCTAssertTrue(HostedTestSupport.waitUntil { model.clicked == ["c"] }, "clicked: \(model.clicked)")
    }

    // MARK: Visibility

    private func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Largest per-channel colour change between two renders inside `rect`
    /// (view coordinates), 0...255.
    private func largestChange(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: NSRect, viewHeight: CGFloat, flipped: Bool) -> Int {
        let scale = CGFloat(a.pixelsWide) / (a.size.width == 0 ? 1 : a.size.width)
        let minX = max(0, Int(rect.minX * scale)), maxX = min(a.pixelsWide - 1, Int(rect.maxX * scale))
        let top = flipped ? rect.minY : viewHeight - rect.maxY
        let minY = max(0, Int(top * scale)), maxY = min(a.pixelsHigh - 1, Int((top + rect.height) * scale))
        var largest = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let diff = [ca.redComponent - cb.redComponent, ca.greenComponent - cb.greenComponent,
                            ca.blueComponent - cb.blueComponent].map { Int(abs($0) * 255) }.max() ?? 0
                largest = max(largest, diff)
            }
        }
        return largest
    }

    /// Re-renders until `row` differs from `reference` by more than `threshold`,
    /// so no fixed wait stands in for SwiftUI's update.
    private func renderUntilRowDiffers(
        from reference: NSBitmapImageRep, window: NSWindow, table: NSTableView, row: Int, threshold: Int = 60
    ) -> NSBitmapImageRep? {
        guard let view = window.contentView else { return nil }
        let rect = view.convert(table.rect(ofRow: row), from: table)
        var latest: NSBitmapImageRep?
        let changed = HostedTestSupport.waitUntil {
            guard let rep = self.snapshot(window) else { return false }
            latest = rep
            return self.largestChange(reference, rep, in: rect, viewHeight: view.bounds.height, flipped: view.isFlipped) > threshold
        }
        return changed ? latest : nil
    }

    func testCursorRingIsVisibleInLightAndDark() throws {
        for dark in [false, true] {
            let model = Model()
            let window = host(model)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let table = try waitForTable(in: window)
            focusList(table, in: window)
            let mode = dark ? "dark" : "light"
            guard let bare = snapshot(window) else { return XCTFail("no snapshot") }
            pressDown(window)   // cursor on "c" (row 2)
            let withCursor = renderUntilRowDiffers(from: bare, window: window, table: table, row: 2)
            XCTAssertNotNil(withCursor, "\(mode): the ring must stand out from the bare row")
            guard let withCursor else { return }
            pressDown(window)   // cursor on "d" (row 3): row 2 loses its ring
            XCTAssertNotNil(renderUntilRowDiffers(from: withCursor, window: window, table: table, row: 2),
                            "\(mode): the ring leaves the row the cursor left")
            HostedTestSupport.tearDown(window)
            self.window = nil
        }
    }

    func testNoRingWhileTheListLacksKeyboardFocus() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        guard let bare = snapshot(window) else { return XCTFail("no snapshot") }
        pressDown(window)
        guard let focused = renderUntilRowDiffers(from: bare, window: window, table: table, row: 2) else {
            return XCTFail("the ring never appeared")
        }
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNotNil(renderUntilRowDiffers(from: focused, window: window, table: table, row: 2),
                        "the ring is drawn only while the list has the keyboard")
    }

    // MARK: Tab

    private func tab(shift: Bool = false, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: shift ? "\u{19}" : "\t",
                         isARepeat: false, keyCode: 48)!
    }

    func testTabLeavesTheListForTheSearchField() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        window.sendEvent(tab(in: window))
        XCTAssertTrue(HostedTestSupport.waitUntil { self.isSearchFieldFocused(window) },
                      "first responder: \(String(describing: window.firstResponder))")
    }

    /// Real Shift-Tab: the back-tab character U+0019 with the Shift flag (not
    /// Tab plus Shift). It must leave the list, going to the previous view.
    func testShiftTabLeavesTheList() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        window.sendEvent(tab(shift: true, in: window))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder !== table },
                      "first responder: \(String(describing: window.firstResponder))")
    }

    func testShiftTabWithAnotherModifierIsNotOurs() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .command], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{19}",
                                     charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48)!
        window.sendEvent(event)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(window.firstResponder === table)
    }

    func testControlTabIsNotOurs() throws {
        let model = Model()
        let window = host(model)
        let table = try waitForTable(in: window)
        focusList(table, in: window)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\t",
                                     charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(event)
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(window.firstResponder === table, "Control-Tab keeps the system meaning")
    }

    // MARK: Search focus (Cmd-F)

    private func isSearchFieldFocused(_ window: NSWindow) -> Bool {
        MacToolbarSearch.isFocused(in: window)
    }

    func testSearchRequestFocusesTheSidebarSearchField() throws {
        let model = Model()
        let requests = MacFocusRequests()
        let window = host(model, requests: requests)
        _ = try waitForTable(in: window)
        XCTAssertNotNil(MacToolbarSearch.searchField(in: window), "SwiftUI put the search field in the toolbar")
        XCTAssertFalse(isSearchFieldFocused(window))
        requests.requestSearch()
        XCTAssertTrue(HostedTestSupport.waitUntil { self.isSearchFieldFocused(window) }, "first responder: \(String(describing: window.firstResponder))")
        XCTAssertFalse(requests.searchPending)
    }

    func testSearchRequestMadeBeforeTheListExistsIsHonouredOnAppear() throws {
        let model = Model()
        let requests = MacFocusRequests()
        requests.requestSearch()   // sidebar was hidden: nothing mounted to receive it
        let window = host(model, requests: requests)
        _ = try waitForTable(in: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { self.isSearchFieldFocused(window) }, "first responder: \(String(describing: window.firstResponder))")
    }

    func testFindsTheToolbarFieldForTheMacOS14Fallback() throws {
        let model = Model()
        let window = host(model)
        _ = try waitForTable(in: window)
        XCTAssertTrue(MacToolbarSearch.focus(in: window))
        XCTAssertTrue(isSearchFieldFocused(window))
        XCTAssertFalse(MacToolbarSearch.focus(in: nil))
    }
}

// MARK: - Hosted: composer (Cmd-L, Tab)

@MainActor
final class MacComposerKeyboardTests: XCTestCase {
    private struct Composer: View {
        let center: NotificationCenter
        @State var text = ""
        @State var isFocused = false
        @State var height: CGFloat = 44
        var body: some View {
            ComposerPasteTextView(
                text: $text, isFocused: $isFocused, measuredHeight: $height, enabled: true,
                onPastedImage: { _ in }, onPastedImageError: { _ in }, editorIdentity: UUID(),
                focusRequestCenter: center
            )
            .frame(width: 300, height: 60)
        }
    }

    private func composerView(in window: NSWindow) -> ComposerTextView? {
        func find(_ view: NSView) -> ComposerTextView? {
            if let c = view as? ComposerTextView { return c }
            for sub in view.subviews { if let c = find(sub) { return c } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func testFocusRequestForThisWindowFocusesTheComposer() throws {
        let center = NotificationCenter()
        let window = HostedTestSupport.host(Composer(center: center), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil { composer = self.composerView(in: window); return composer != nil })
        let view = try XCTUnwrap(composer)
        XCTAssertFalse(window.firstResponder === view)
        center.post(name: .macFocusComposerRequested, object: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === view })
    }

    func testFocusRequestForAnotherWindowIsIgnored() throws {
        let center = NotificationCenter()
        let window = HostedTestSupport.host(Composer(center: center), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil { composer = self.composerView(in: window); return composer != nil })
        center.post(name: .macFocusComposerRequested, object: other)
        HostedTestSupport.settle(0.2)
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testFocusRequestTakesFocusFromTheSearchFieldWithoutLeavingAStaleHold() throws {
        let center = NotificationCenter()
        let window = HostedTestSupport.host(Composer(center: center), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil { composer = self.composerView(in: window); return composer != nil })
        let view = try XCTUnwrap(composer)
        view.heldFocusForRoute = true   // a route hold from an earlier Kanban visit
        center.post(name: .macFocusComposerRequested, object: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === view })
        XCTAssertFalse(view.heldFocusForRoute, "an explicit request replaces a held focus")
    }

    func testFocusRequestIsRefusedWhileASheetIsAttached() throws {
        let composer = ComposerTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = composer
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.close(); sheet.close() }
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(nil))
        window.beginSheet(sheet)
        XCTAssertNotNil(window.attachedSheet, "the sheet is attached")
        defer { window.endSheet(sheet) }
        XCTAssertFalse(composer.focusFromCommand())
        XCTAssertFalse(window.firstResponder === composer)
    }

    /// Cmd-L from another pane, end to end: the route holds the hidden chat's
    /// focus, the command returns the route to chat and focus comes back.
    func testFocusRequestFromAnotherPaneReturnsToChatAndFocuses() throws {
        // ComposerPasteTextView reads the standard defaults; put the key back after.
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let center = NotificationCenter()
        let window = HostedTestSupport.host(Composer(center: center), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil { composer = self.composerView(in: window); return composer != nil })
        let view = try XCTUnwrap(composer)
        center.post(name: .macFocusComposerRequested, object: window)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === view })

        defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder !== view }, "hidden chat gives up focus")
        XCTAssertTrue(view.heldFocusForRoute)

        MacKeyboardActions.focusComposer(window: window, defaults: defaults, center: center)
        XCTAssertEqual(defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.sessions.rawValue)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === view }, "focus is back in the composer")
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(window.firstResponder === view, "and stays there once the route update lands")
    }

    // MARK: Tab

    private func tabEvent(shift: Bool, option: Bool = false, in window: NSWindow) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil,
                                characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: shift ? "\u{19}" : "\t",
                                isARepeat: false, keyCode: 48)!
    }

    /// A list, a text field standing in for the search field, and the composer.
    private func loopWindow() -> (window: NSWindow, list: NSTableView, field: NSTextField, composer: ComposerTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let list = NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        list.addTableColumn(column)
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 190, width: 120, height: 100))
        scroll.documentView = list
        let field = NSTextField(frame: NSRect(x: 10, y: 150, width: 120, height: 24))
        let composer = ComposerTextView()
        composer.frame = NSRect(x: 150, y: 10, width: 200, height: 40)
        [scroll, field, composer].forEach { content.addSubview($0) }
        window.contentView = content
        window.autorecalculatesKeyViewLoop = false
        scroll.nextKeyView = nil
        list.nextKeyView = field
        field.nextKeyView = composer
        composer.nextKeyView = list
        window.orderFront(nil)
        return (window, list, field, composer)
    }

    func testTabInTheComposerMovesAlongTheKeyViewLoopInsteadOfTyping() {
        let loop = loopWindow()
        defer { loop.window.close() }
        XCTAssertTrue(loop.window.makeFirstResponder(loop.composer))
        loop.window.sendEvent(tabEvent(shift: false, in: loop.window))
        XCTAssertEqual(loop.composer.string, "", "Tab must not type a tab character")
        XCTAssertTrue(loop.window.firstResponder === loop.list, "next in the loop after the composer")
    }

    func testShiftTabInTheComposerMovesBackwards() {
        let loop = loopWindow()
        defer { loop.window.close() }
        XCTAssertTrue(loop.window.makeFirstResponder(loop.composer))
        loop.window.sendEvent(tabEvent(shift: true, in: loop.window))
        XCTAssertEqual(loop.composer.string, "")
        let responder = loop.window.firstResponder
        XCTAssertTrue(responder === loop.field || (responder as? NSText)?.delegate === loop.field,
                      "previous in the loop before the composer: \(String(describing: responder))")
    }

    /// The real SwiftUI session list beside the real composer twin: Tab and
    /// Shift-Tab travel between them on AppKit's own key view loop.
    private struct ListAndComposer: View {
        let center: NotificationCenter
        @State var text = ""
        @State var isFocused = false
        @State var height: CGFloat = 44
        var body: some View {
            HStack(spacing: 0) {
                List {
                    ForEach(["a", "b"], id: \.self) { id in
                        Button {} label: { Text(id).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                            .buttonStyle(.plain)
                            .modifier(MacSessionCursorRow(id: id))
                    }
                }
                .modifier(MacSessionListKeyboard(ids: ["a", "b"], activeID: nil, open: { _ in }, requests: MacFocusRequests()))
                .frame(width: 250)
                ComposerPasteTextView(
                    text: $text, isFocused: $isFocused, measuredHeight: $height, enabled: true,
                    onPastedImage: { _ in }, onPastedImageError: { _ in }, editorIdentity: UUID(),
                    focusRequestCenter: center
                )
                .frame(width: 300, height: 60)
            }
        }
    }

    func testTabTravelsBetweenTheSwiftUIListAndTheComposer() throws {
        let window = HostedTestSupport.host(ListAndComposer(center: NotificationCenter()), size: NSSize(width: 560, height: 200))
        defer { HostedTestSupport.tearDown(window) }
        func findAll<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { findAll(type, $0) }
        }
        var table: NSTableView?
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil {
            table = findAll(NSTableView.self, window.contentView!).first
            composer = self.composerView(in: window)
            return table != nil && composer != nil
        })
        let list = try XCTUnwrap(table), field = try XCTUnwrap(composer)
        XCTAssertTrue(window.makeFirstResponder(list))
        window.sendEvent(tabEvent(shift: false, in: window))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === field },
                      "list -> composer: \(String(describing: window.firstResponder))")
        window.sendEvent(tabEvent(shift: true, in: window))
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === list },
                      "composer -> list: \(String(describing: window.firstResponder))")
    }
}
