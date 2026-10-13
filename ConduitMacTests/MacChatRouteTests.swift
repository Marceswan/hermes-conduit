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
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.sessions.rawValue), "")
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.kanban.rawValue), SidebarTab.kanban.displayName)
        XCTAssertEqual(MacChatRoute.navigationTitle(tabRaw: SidebarTab.bots.rawValue), SidebarTab.bots.displayName)
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

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
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
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FocusedComposer())
        window.orderFront(nil)
        defer { window.close() }
        spin(0.3)
        guard let composer = composerTextView(in: window) else { return XCTFail("composer not found") }
        XCTAssertTrue(window.firstResponder === composer, "focused composer takes focus while chat is shown")

        defaults.set(SidebarTab.kanban.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        spin(0.3)
        XCTAssertFalse(window.firstResponder === composer, "hidden chat gives up focus")

        defaults.set(SidebarTab.sessions.rawValue, forKey: MacSidebarState.tabDefaultsKey)
        spin(0.3)
        XCTAssertTrue(window.firstResponder === composer, "focus returns with the chat")
    }
}

@MainActor
final class MacSessionOpenSignalTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

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

    /// Drives the router's real handler: every non-chat pane returns to chat on
    /// the signal, and nothing else (sidebar chrome posts nothing) moves it.
    func testSignalReturnsEveryPaneToChatAndNothingElseDoes() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MacSidebarState.tabDefaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MacSidebarState.tabDefaultsKey) }
            else { defaults.removeObject(forKey: MacSidebarState.tabDefaultsKey) }
        }
        for tab in [SidebarTab.bots, .cron, .kanban] {
            defaults.set(tab.rawValue, forKey: MacSidebarState.tabDefaultsKey)
            let host = NSHostingView(rootView:
                MacDetailRouter(chat: { Color.clear })
                    .environmentObject(AppStateRuntimeRegistry.shared.appState)
                    .frame(width: 600, height: 400))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            spin(0.3)
            XCTAssertEqual(defaults.string(forKey: MacSidebarState.tabDefaultsKey), tab.rawValue,
                           "\(tab): staying put without a signal")
            NotificationCenter.default.post(name: .macSessionOpenRequested, object: nil)
            spin(0.3)
            XCTAssertEqual(defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.sessions.rawValue,
                           "\(tab): returns to chat on the signal")
            window.close()
        }
    }
}
