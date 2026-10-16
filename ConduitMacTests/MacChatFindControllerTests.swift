import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindControllerTests: XCTestCase {
    /// Mutable transcript the controller reads through its environment.
    final class Transcript {
        var messages: [ChatMessage]
        var hasEarlier = false
        var shown = true
        init(_ messages: [ChatMessage]) { self.messages = messages }
    }

    private static let quiet = MacChatFindController.Timing(
        debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .seconds(60), maxRevealRetries: 3
    )

    private var revealed: [String] = []
    private var scrolled: [(String, NSRange)] = []

    private func message(_ id: String, _ text: String, role: MessageRole = .assistant) -> ChatMessage {
        ChatMessage(id: id, role: role, content: text, timestamp: "")
    }

    private func makeController(
        _ transcript: Transcript,
        timing: MacChatFindController.Timing = MacChatFindControllerTests.quiet
    ) -> MacChatFindController {
        let controller = MacChatFindController(
            environment: .init(
                messages: { transcript.messages },
                hasEarlierMessages: { transcript.hasEarlier },
                isTranscriptShown: { transcript.shown }
            ),
            timing: timing,
            scroller: { [unowned self] view, range in self.scrolled.append((view.string, range)) }
        )
        controller.reveal = { [unowned self] id in self.revealed.append(id) }
        // Close first (cancels pending reveal and search tasks), then let go of the test.
        addTeardownBlock { @MainActor [weak controller] in controller?.close() }
        return controller
    }

    private func mounted(_ controller: MacChatFindController, _ id: String, _ text: String) -> NSTextView {
        let view = SelectableTextView.makeTextView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        view.string = text
        controller.registry.register(view, messageID: id)
        return view
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    /// Polls without blocking the main actor (a run-loop spin would starve the
    /// controller's own main-actor tasks).
    private func eventually(timeout: Duration = .seconds(5), _ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !predicate() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func search(_ controller: MacChatFindController, _ query: String) async {
        controller.query = query
        await controller.settled()
    }

    // MARK: search

    func testTypingSelectsTheNewestHitAndHighlightsMountedViews() async {
        let transcript = Transcript([message("m1", "alpha beta"), message("m2", "beta gamma"), message("m3", "delta")])
        let controller = makeController(transcript)
        let v1 = mounted(controller, "m1", "alpha beta")
        let v2 = mounted(controller, "m2", "beta gamma")
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        XCTAssertEqual(background(v1, at: 6), MacChatFindColors.match)
        XCTAssertEqual(background(v2, at: 0), MacChatFindColors.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "2 of 2")
    }

    func testNonSearchableRowsNeverMatchOrHighlight() async {
        let transcript = Transcript([message("m1", "beta"), message("t1", "beta", role: .tool)])
        let controller = makeController(transcript)
        let tool = mounted(controller, "t1", "beta")
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 1)
        XCTAssertNil(background(tool, at: 0))
    }

    func testNextAndPreviousMoveTheCurrentHitAndScroll() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        let views = ["m1", "m2", "m3"].map { mounted(controller, $0, "beta") }
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.position, 3)
        scrolled.removeAll()
        controller.next()
        XCTAssertEqual(controller.state.position, 1, "wraps")
        XCTAssertEqual(background(views[0], at: 0), MacChatFindColors.current)
        XCTAssertEqual(background(views[2], at: 0), MacChatFindColors.match)
        controller.previous()
        XCTAssertEqual(controller.state.position, 3)
        XCTAssertEqual(scrolled.count, 2, "each step scrolls once to a mounted view")
        XCTAssertTrue(revealed.isEmpty, "mounted rows need no engine reveal")
    }

    func testStepsAreIgnoredWhileClosedOrWithoutHits() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.next()
        XCTAssertEqual(controller.state.count, 0)
        controller.open()
        await search(controller, "zzz")
        controller.next()
        controller.previous()
        XCTAssertNil(controller.state.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "No matches")
    }

    func testRefiningTheQueryStaysNearTheCurrentHit() async {
        // Hits for "ab": m1 twice, m2, m3. Newest is m3; one step back is m2.
        let transcript = Transcript([message("m1", "ab abc"), message("m2", "abc"), message("m3", "ab")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "ab")
        XCTAssertEqual(controller.state.count, 4)
        XCTAssertEqual(controller.state.current?.messageID, "m3")
        controller.previous()
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        await search(controller, "abc")   // m3 no longer matches; m2 still does
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
    }

    func testClearingTheQueryClearsEverything() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        let view = mounted(controller, "m1", "beta")
        controller.open()
        await search(controller, "beta")
        XCTAssertNotNil(background(view, at: 0))
        await search(controller, "")
        XCTAssertEqual(controller.state.count, 0)
        XCTAssertNil(background(view, at: 0))
    }

    // MARK: unmounted rows

    func testAnUnmountedRowIsRevealedThenPlacedWhenItsViewRegisters() async {
        let transcript = Transcript([message("m1", "find the needle here"), message("m2", "other")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")
        XCTAssertEqual(revealed, ["m1"])
        XCTAssertTrue(scrolled.isEmpty, "no view yet, nothing to scroll inside")
        _ = mounted(controller, "m1", "find the needle here")
        await controller.settled()
        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(scrolled.first?.1, NSRange(location: 9, length: 6))
    }

    func testRevealRetriesAreBounded() async {
        let transcript = Transcript([message("m1", "needle")])
        let timing = MacChatFindController.Timing(
            debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .milliseconds(15), maxRevealRetries: 3
        )
        let controller = makeController(transcript, timing: timing)
        controller.open()
        await search(controller, "needle")
        let reached = await eventually { self.revealed.count == 3 }
        XCTAssertTrue(reached)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(revealed.count, 3, "stops after maxRevealRetries")
    }

    func testClosingCancelsAPendingRevealAndLateRegistrationDoesNotScroll() async {
        let transcript = Transcript([message("m1", "needle")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")
        controller.close()
        let late = mounted(controller, "m1", "needle")
        await controller.settled()
        XCTAssertTrue(scrolled.isEmpty)
        XCTAssertNil(background(late, at: 0), "no highlight after close")
    }

    func testANewNavigationCancelsTheOldPendingReveal() async {
        let transcript = Transcript([message("m1", "needle"), message("m2", "needle")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "needle")          // current m2, pending m2
        controller.previous()                       // current m1, pending m1
        _ = mounted(controller, "m2", "needle")
        await controller.settled()
        XCTAssertTrue(scrolled.isEmpty, "m2 is no longer the target")
        _ = mounted(controller, "m1", "needle")
        await controller.settled()
        XCTAssertEqual(scrolled.count, 1)
    }

    func testAMountedMessageWhoseDrawnTextHasFewerHitsStillScrollsToItsFirstView() async {
        let transcript = Transcript([message("m1", "needle needle")])
        let controller = makeController(transcript)
        let view = mounted(controller, "m1", "needle")   // drawn text shows one hit, projection two
        controller.open()
        await search(controller, "needle")               // current ordinal 1 -> no such hit in the view
        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(scrolled.first?.0, view.string)
    }

    // MARK: transcript changes

    func testARefreshKeepsTheCurrentHitAndDoesNotScroll() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        for id in ["m1", "m2", "m3"] { _ = mounted(controller, id, "beta") }
        controller.open()
        await search(controller, "beta")
        controller.previous()                         // m2
        scrolled.removeAll()
        transcript.messages.append(message("m4", "beta"))
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 4)
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        XCTAssertTrue(scrolled.isEmpty)
    }

    func testASessionSwitchFallsBackWithoutLeavingTheRange() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        transcript.messages = [message("x1", "beta"), message("x2", "nope"), message("x3", "beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "x3")
        transcript.messages = []
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertNil(controller.state.current)
        XCTAssertEqual(MacChatFindLabel.text(query: controller.query, state: controller.state), "No matches")
    }

    func testAnEditedMessageIsSearchedAgain() async {
        let transcript = Transcript([message("m1", "alpha")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 0)
        transcript.messages = [message("m1", "alpha beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 1)
    }

    func testRefreshWhileClosedDoesNothing() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 0)
    }

    func testTheBarClosesWhenTheTranscriptStopsBeingShown() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.open()
        XCTAssertTrue(controller.isOpen)
        transcript.shown = false
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertFalse(controller.isOpen)
    }

    func testARemovedCurrentMessageFallsToTheNearestRemainingHitNotTheNewest() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta"), message("m4", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        controller.previous()
        controller.previous()                         // m2
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        transcript.messages = [message("m1", "beta"), message("m3", "beta"), message("m4", "beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 3)
        XCTAssertEqual(controller.state.current?.messageID, "m3", "the hit after the removed one, not the newest")
    }

    func testARemovedLastMessageFallsToTheNewestRemainingHit() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.current?.messageID, "m3")
        transcript.messages = [message("m1", "beta"), message("m2", "beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.state.current?.messageID, "m2")
    }

    func testAHitNoMountedViewDrawsKeepsTheCountAndStopsAfterTheRetries() async {
        let transcript = Transcript([message("m1", "see needle"), message("m2", "other")])
        let timing = MacChatFindController.Timing(
            debounce: .zero, refresh: .zero, placement: [.zero], revealRetry: .milliseconds(15), maxRevealRetries: 3
        )
        let controller = makeController(transcript, timing: timing)
        _ = mounted(controller, "m1", "nothing drawn here")
        controller.open()
        await search(controller, "needle")
        try? await Task.sleep(for: .milliseconds(200))   // the 3 retries at 15 ms are long over
        XCTAssertEqual(revealed, ["m1"], "a mounted row that lacks the hit is requested once, not re-yanked per retry")
        XCTAssertEqual(controller.state.count, 1)
        XCTAssertEqual(controller.state.current?.messageID, "m1")
        XCTAssertEqual(scrolled.count, 1, "the message is brought into view once, no loop")
    }

    func testRepeatedRegistrationsOfThePendingRowDoNotRestartPlacement() async {
        let transcript = Transcript([message("m1", "find the needle here")])
        let timing = MacChatFindController.Timing(
            debounce: .zero, refresh: .zero, placement: [.milliseconds(30), .milliseconds(30)], revealRetry: .seconds(60), maxRevealRetries: 3
        )
        let controller = makeController(transcript, timing: timing)
        controller.open()
        await search(controller, "needle")
        let view = mounted(controller, "m1", "find the needle here")
        let first = await eventually { self.scrolled.count == 1 }
        XCTAssertTrue(first, "the first placement pass ran")
        // updateNSView re-registers the row on every update, mid-placement.
        for _ in 0..<3 { controller.registry.register(view, messageID: "m1") }
        await controller.settled()
        XCTAssertEqual(scrolled.count, 2, "exactly the two configured passes, no restarted placement")
    }

    func testNextStepsFromTheCurrentHitWhileARefreshIsQueued() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        controller.previous()                         // m2
        controller.transcriptDidChange()              // refresh queued, not yet run
        controller.next()
        XCTAssertEqual(controller.state.current?.messageID, "m3", "stepped once from m2")
        controller.transcriptDidChange()
        controller.previous()
        XCTAssertEqual(controller.state.current?.messageID, "m2")
        await controller.settled()
        XCTAssertEqual(controller.state.current?.messageID, "m2")
    }

    func testATypedQueryStillAppliesBeforeAStepInsideTheDebounce() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "alpha")])
        let controller = makeController(transcript)
        controller.open()
        controller.query = "beta"                     // queued, not yet run
        controller.next()
        XCTAssertEqual(controller.state.count, 2)
        XCTAssertEqual(controller.state.current?.messageID, "m2", "landed on the typed query's selection")
    }

    // MARK: real publishers (willSet timing)

    /// Publishes in willSet exactly like AppState's @Published members.
    final class Flags: ObservableObject {
        @Published var shown = true
        @Published var hasEarlier = false
    }

    func testChangesAreReadAfterTheWriteNotInWillSet() async {
        let flags = Flags()
        let controller = MacChatFindController(
            environment: .init(
                messages: { [] },
                hasEarlierMessages: { flags.hasEarlier },
                isTranscriptShown: { flags.shown }
            ),
            timing: Self.quiet,
            scroller: { _, _ in }
        )
        addTeardownBlock { @MainActor [weak controller] in controller?.close() }
        controller.observe(
            flags.$shown.dropFirst().map { _ in () }
                .merge(with: flags.$hasEarlier.dropFirst().map { _ in () })
                .eraseToAnyPublisher()
        )
        controller.open()
        XCTAssertFalse(controller.showsLoadedOnlyNote)
        flags.hasEarlier = true
        await controller.settled()
        XCTAssertTrue(controller.showsLoadedOnlyNote, "the note reads the new value")
        flags.shown = false
        await controller.settled()
        XCTAssertFalse(controller.isOpen, "the bar closes when the transcript is replaced")
    }

    func testBoundToARealAppStateAMessageChangeRefreshesTheHits() async {
        let suite = HostedTestSupport.makeSuite()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatFindControllerTests.\(UUID().uuidString)", isDirectory: true)
        let appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        addTeardownBlock {
            HostedTestSupport.dropSuite(suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        let controller = MacChatFindController(timing: Self.quiet, scroller: { _, _ in })
        addTeardownBlock { @MainActor [weak controller] in controller?.close() }
        controller.bind(to: appState)
        appState.messages = [message("m1", "beta")]
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.state.count, 1)
        appState.messages = [message("m1", "beta"), message("m2", "beta")]
        await controller.settled()
        XCTAssertEqual(controller.state.count, 2, "the refresh saw the written messages")
    }

    // MARK: open and close

    func testOpenIsRefusedWhenTheTranscriptIsNotShown() {
        let transcript = Transcript([message("m1", "beta")])
        transcript.shown = false
        let controller = makeController(transcript)
        controller.open()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.isAvailable)
    }

    func testOpenAgainRefocusesWithoutReplacingTheRestoreTarget() {
        let transcript = Transcript([])
        let controller = makeController(transcript)
        var firstRestores = 0, secondRestores = 0
        controller.open(restoreFocus: { firstRestores += 1 })
        let token = controller.focusToken
        controller.open(restoreFocus: { secondRestores += 1 })
        XCTAssertGreaterThan(controller.focusToken, token)
        controller.close()
        XCTAssertEqual(firstRestores, 1)
        XCTAssertEqual(secondRestores, 0)
        controller.close()
        XCTAssertEqual(firstRestores, 1, "closing twice restores once")
    }

    func testCloseReleasesTheProjectionCacheAndThePreviousIDs() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta"), message("m3", "gamma")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        XCTAssertEqual(controller.projectionCacheCount, 3)
        XCTAssertEqual(controller.previousIDs, ["m1", "m2", "m3"])
        controller.close()
        XCTAssertEqual(controller.projectionCacheCount, 0, "projected text of the transcript is dropped on close")
        XCTAssertTrue(controller.previousIDs.isEmpty)
        controller.open()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 2, "reopening primes and searches again")
        XCTAssertEqual(controller.projectionCacheCount, 3)
    }

    func testASessionSwitchReplacesTheCacheAndThePreviousIDs() async {
        let transcript = Transcript([message("m1", "beta"), message("m2", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        transcript.messages = [message("x1", "beta")]
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.projectionCacheCount, 1, "the old session's text is gone")
        XCTAssertEqual(controller.previousIDs, ["x1"])
        transcript.messages = []
        controller.transcriptDidChange()
        await controller.settled()
        XCTAssertEqual(controller.projectionCacheCount, 0)
        XCTAssertTrue(controller.previousIDs.isEmpty)
    }

    func testReopeningKeepsTheQueryAndSearchesAgain() async {
        let transcript = Transcript([message("m1", "beta")])
        let controller = makeController(transcript)
        controller.open()
        await search(controller, "beta")
        controller.close()
        XCTAssertEqual(controller.state.count, 0)
        XCTAssertEqual(controller.query, "beta")
        controller.open()
        await controller.settled()
        XCTAssertEqual(controller.state.count, 1)
    }

    func testTheLoadedOnlyNoteFollowsTheTranscript() {
        let transcript = Transcript([message("m1", "beta")])
        transcript.hasEarlier = true
        let controller = makeController(transcript)
        controller.open()
        XCTAssertTrue(controller.showsLoadedOnlyNote)
    }

    // MARK: responders and windows

    func testOwnsTheComposerMessageViewsAndTheTranscript() {
        let controller = makeController(Transcript([]))
        let view = mounted(controller, "m1", "beta")
        XCTAssertTrue(controller.ownsResponder(ComposerTextView()))
        XCTAssertTrue(controller.ownsResponder(view))
        XCTAssertFalse(controller.ownsResponder(NSView()))
        XCTAssertFalse(controller.ownsResponder(nil))
    }

    func testTheFieldEditorOfTheBarsFieldIsOwned() {
        let controller = makeController(Transcript([]))
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        controller.field = field
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(controller.ownsResponder(window.firstResponder))
    }

    func testControllersAreLookedUpPerWindowAndHeldWeakly() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        weak var weakController: MacChatFindController?
        autoreleasepool {
            let controller = makeController(Transcript([]))
            weakController = controller
            MacChatFindControllers.register(controller, in: window)
            XCTAssertTrue(MacChatFindControllers.controller(for: window) === controller)
        }
        XCTAssertNil(weakController)
        XCTAssertNil(MacChatFindControllers.controller(for: window))
        XCTAssertNil(MacChatFindControllers.controller(for: nil))
    }
}
