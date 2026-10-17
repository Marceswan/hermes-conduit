import SwiftUI
import XCTest
@testable import ConduitMac

final class MacChatRouteTests: XCTestCase {
    func testChatActiveOnlyForSessionsTab() {
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: SidebarTab.sessions.rawValue))
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: nil))
        XCTAssertTrue(MacChatRoute.isChatActive(tabRaw: "Capabilities"), "removed raw values migrate to Sessions")
        for tab in [SidebarTab.bots, .cron, .kanban] {
            XCTAssertFalse(MacChatRoute.isChatActive(tabRaw: tab.rawValue))
        }
    }

    func testHiddenChatTitleIsPaneName() {
        // The title string stays the pane name (Window menu); on macOS 26+ the toolbar hides it (MacPaneTitleTests).
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.sessions.rawValue), "")
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.kanban.rawValue), SidebarTab.kanban.displayName)
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.bots.rawValue), SidebarTab.bots.displayName)
    }

    func testHomeIsAPaneNotChat() {
        XCTAssertFalse(MacChatRoute.isChatActive(tabRaw: "Home"))
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: "Home"), SidebarTab.home.displayName)
        XCTAssertEqual(SidebarTab.home.rawValue, "Home")
        XCTAssertEqual(SidebarTab.allCases.last, .home, "upstream's order (shortcuts, palette) keeps Home last; only the Mac strip puts it first")
        XCTAssertEqual(MacSidebarTabOrder.strip.first, .home)
        XCTAssertEqual(MacSidebarTabOrder.strip.last, .kanban)
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Home"), .home)
    }

    func testColumnMetricsFitWindowMinimum() {
        XCTAssertLessThanOrEqual(
            MacSidebarState.sidebarMaxWidth + MacSidebarState.detailMinWidth,
            MacSidebarState.windowMinWidth,
            "detail pane would clip at the widest sidebar"
        )
        XCTAssertLessThanOrEqual(MacSidebarState.sidebarMinWidth, MacSidebarState.sidebarIdealWidth)
        XCTAssertLessThanOrEqual(MacSidebarState.sidebarIdealWidth, MacSidebarState.sidebarMaxWidth)
    }
}

@MainActor
final class MacHiddenChatFocusTests: XCTestCase {
    private func makeWindow(with views: [NSView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        for (i, view) in views.enumerated() {
            view.frame = NSRect(x: 10, y: 10 + i * 60, width: 200, height: 40)
            content.addSubview(view)
        }
        window.contentView = content
        return window
    }

    func testResignsFocusedComposerWithoutReportingFocusLoss() {
        let composer = ComposerTextView()
        var reported: [Bool] = []
        composer.onFocusChange = { reported.append($0) }
        let window = makeWindow(with: [composer])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertEqual(reported, [true])
        XCTAssertTrue(MacChatRoute.resignComposerFocus(in: window))
        XCTAssertFalse(window.firstResponder === composer)
        XCTAssertTrue(composer.heldFocusForRoute)
        XCTAssertEqual(reported, [true], "a route resign must not look like the user leaving the composer")
    }

    func testLeavesOtherResponderAlone() {
        let field = NSTextField(frame: .zero)
        let window = makeWindow(with: [field])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(MacChatRoute.resignComposerFocus(in: window))
        XCTAssertFalse(window.firstResponder is ComposerTextView)
        XCTAssertFalse(MacChatRoute.resignComposerFocus(in: nil))
    }

    func testRestoresHeldFocusOnReturn() {
        let composer = ComposerTextView()
        var reported: [Bool] = []
        composer.onFocusChange = { reported.append($0) }
        let window = makeWindow(with: [composer])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        MacChatRoute.resignComposerFocus(in: window)
        XCTAssertTrue(composer.restoreFocusIfHeld())
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertFalse(composer.heldFocusForRoute)
    }

    func testNoRestoreWhenComposerNeverHeldFocus() {
        let composer = ComposerTextView()
        let window = makeWindow(with: [composer])
        defer { window.close() }
        XCTAssertFalse(composer.restoreFocusIfHeld())
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testRestoreDoesNotStealFromAnotherTextField() {
        let composer = ComposerTextView()
        let field = NSTextField(frame: .zero)
        var reported: [Bool] = []
        composer.onFocusChange = { reported.append($0) }
        let window = makeWindow(with: [composer, field])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        MacChatRoute.resignComposerFocus(in: window)
        XCTAssertTrue(window.makeFirstResponder(field), "sidebar search / pane field takes the keyboard")
        XCTAssertFalse(composer.restoreFocusIfHeld())
        XCTAssertFalse(window.firstResponder === composer)
        XCTAssertTrue(window.firstResponder is NSText, "the field editor keeps focus")
        XCTAssertEqual(reported.last, false, "owner is told focus is gone so it stops re-requesting")
        XCTAssertFalse(composer.heldFocusForRoute)
    }

    // MARK: window becomes key again

    func testWindowReturnFocusesTheComposer() {
        let composer = ComposerTextView()
        let window = makeWindow(with: [composer])
        defer { window.close() }
        window.makeFirstResponder(nil)
        XCTAssertTrue(composer.focusOnWindowReturn())
        XCTAssertTrue(window.firstResponder === composer)
    }

    func testWindowReturnLeavesAnotherTextFieldFocused() {
        let composer = ComposerTextView()
        let field = NSTextField(frame: .zero)
        let window = makeWindow(with: [composer, field])
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field), "sidebar search was being typed in")
        XCTAssertFalse(composer.focusOnWindowReturn())
        XCTAssertTrue(window.firstResponder is NSText)
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testWindowReturnUnderASheetDoesNothing() {
        let composer = ComposerTextView()
        let window = makeWindow(with: [composer])
        defer { window.close() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.orderFront(nil)
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { window.attachedSheet != nil })
        // Ordering the window front made the composer its initial first responder.
        window.makeFirstResponder(nil)
        XCTAssertFalse(composer.focusOnWindowReturn())
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testWindowReturnSkipsAReadOnlyComposer() {
        let composer = ComposerTextView()
        composer.isEditable = false
        let window = makeWindow(with: [composer])
        defer { window.close() }
        window.makeFirstResponder(nil)
        XCTAssertFalse(composer.focusOnWindowReturn())
    }

    /// End to end through updateNSView: focused composer, leave chat, return.
    private struct FocusedComposer: View {
        @State var text = ""
        @State var isFocused = true
        @State var height: CGFloat = 44
        var body: some View {
            ComposerPasteTextView(
                text: $text,
                isFocused: $isFocused,
                measuredHeight: $height,
                enabled: true,
                onPastedImage: { _ in },
                onPastedImageError: { _ in },
                editorIdentity: UUID()
            )
            .frame(width: 300, height: 60)
        }
    }

    private func composerTextView(in window: NSWindow) -> ComposerTextView? {
        func find(_ view: NSView) -> ComposerTextView? {
            if let c = view as? ComposerTextView { return c }
            for sub in view.subviews { if let c = find(sub) { return c } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func testComposerRefocusesWhenRouteReturnsToChat() {
        // ComposerPasteTextView reads the standard defaults; put the key back after.
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = HostedTestSupport.host(FocusedComposer(), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil {
            composer = composerTextView(in: window)
            return composer != nil && window.firstResponder === composer
        }, "focused composer takes focus while chat is shown")
        guard let composer else { return }

        defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder !== composer },
                      "hidden chat gives up focus")

        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { window.firstResponder === composer },
                      "focus returns with the chat")
    }

    /// End to end: the hosted composer takes focus when its window becomes
    /// key, only while chat is shown.
    func testComposerFocusesWhenItsWindowBecomesKey() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = HostedTestSupport.host(FocusedComposer(isFocused: false), size: NSSize(width: 300, height: 100))
        defer { HostedTestSupport.tearDown(window) }
        var composer: ComposerTextView?
        XCTAssertTrue(HostedTestSupport.waitUntil { composer = composerTextView(in: window); return composer != nil })
        guard let composer else { return }
        window.makeFirstResponder(nil)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(window.firstResponder === composer, "a chat hidden under Kanban does not take focus")

        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        XCTAssertFalse(window.firstResponder === composer, "another window becoming key is ignored")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === composer, "the chat's composer takes focus")
    }
}

@MainActor
final class MacSessionOpenSignalTests: XCTestCase {
    private func count(_ body: () -> Void) -> Int {
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .macSessionOpenRequested, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return posts
    }

    func testRequestOpenSessionPostsSignal() {
        let appState = AppStateRuntimeRegistry.shared.appState
        let posts = count { appState.requestOpenSession("mac-signal-test").cancel() }
        XCTAssertEqual(posts, 1)
    }

    func testOpenBotChatPostsSignal() async {
        let appState = AppStateRuntimeRegistry.shared.appState
        let bot = BotProfile(
            name: "signal-test", botTitle: nil, displayName: "", profileDescription: "",
            model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
            appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .macSessionOpenRequested, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = await appState.openBotChat(for: bot)
        XCTAssertEqual(posts, 1)
    }

    private final class Mounted { var value = false }

    private struct MountProbe: View {
        let mounted: Mounted
        var body: some View { Color.clear.onAppear { mounted.value = true } }
    }

    /// Drives the router's real handler. Each router gets its own defaults
    /// suite, its own NotificationCenter and its own AppState, so neither the
    /// live app's router, another test's post, nor another test's change to
    /// the process-wide AppState's active session (the router also returns to
    /// chat on that) can reach it: every non-chat pane returns to chat on the
    /// signal, and nothing else moves it.
    func testSignalReturnsEveryPaneToChatAndNothingElseDoes() {
        for tab in [SidebarTab.bots, .cron, .kanban] {
            let suite = HostedTestSupport.makeSuite()
            defer { HostedTestSupport.dropSuite(suite) }
            let fixture = MacSharedBaseAppStateFixture()
            defer { fixture.tearDown() }
            let center = NotificationCenter()
            suite.defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            let mounted = Mounted()
            let window = HostedTestSupport.host(
                MacDetailRouter(defaults: suite.defaults, notificationCenter: center, chat: { MountProbe(mounted: mounted) })
                    .environmentObject(fixture.appState)
                    .frame(width: 600, height: 400),
                size: NSSize(width: 600, height: 400))
            defer { HostedTestSupport.tearDown(window) }
            XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 15) { mounted.value }, "\(tab): router mounted")
            HostedTestSupport.settle()
            XCTAssertEqual(suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey), tab.rawValue,
                           "\(tab): staying put without a signal")
            center.post(name: .macSessionOpenRequested, object: nil)
            XCTAssertTrue(
                HostedTestSupport.waitUntil(timeout: 15) {
                    suite.defaults.string(forKey: MacSidebarState.tabDefaultsKey) == SidebarTab.sessions.rawValue
                },
                "\(tab): returns to chat on the signal")
        }
    }
}
