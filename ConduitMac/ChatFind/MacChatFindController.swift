import AppKit
import Combine

/// One window's whole-chat find (D23): query, hits, navigation, highlights.
/// Created per main window in `rootContent`, looked up by `NSWindow` for the
/// menu commands. Nothing here touches `AppState` except through `bind`.
@MainActor
final class MacChatFindController: ObservableObject {
    struct Timing {
        var debounce: Duration = .milliseconds(120)
        var refresh: Duration = .milliseconds(150)
        /// Delays of the placement passes after a pending row registers.
        var placement: [Duration] = [.milliseconds(50), .milliseconds(250)]
        var revealRetry: Duration = .milliseconds(250)
        var maxRevealRetries = 6
    }

    struct Environment {
        var messages: () -> [ChatMessage]
        var hasEarlierMessages: () -> Bool
        /// False while a group-chat room replaces the transcript.
        var isTranscriptShown: () -> Bool
        /// False while Bots / Cron / Kanban is the shown sidebar destination:
        /// `MacDetailRouter` keeps the chat (and this bar) mounted but hidden.
        var isChatRouteActive: () -> Bool = { true }

        static let empty = Environment(messages: { [] }, hasEarlierMessages: { false }, isTranscriptShown: { false })
    }

    @Published private(set) var isOpen = false
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var state = MacChatFindState()
    /// Bumped by every `open`; the bar focuses and selects its field on change.
    @Published private(set) var focusToken = 0
    @Published private(set) var showsLoadedOnlyNote = false

    let registry = MacChatFindRegistry()
    /// Asks the scroll engine to bring a row on screen; set by `attach(engine:)`.
    var reveal: (String) -> Void = { _ in }
    /// The bar's search field, so a first responder can be recognised as ours.
    weak var field: NSSearchField?
    /// Speaks a settled result to VoiceOver; replaced in tests.
    var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    private var lastAnnouncement: String?

    private var environment: Environment
    private let timing: Timing
    private let scroller: @MainActor (NSTextView, NSRange) -> Void
    private let cache = MacChatFindTextCache()
    private var searchable: Set<String> = []
    private var searchTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    /// Kind of the queued search: a typed query (true) or a transcript refresh.
    private var queuedSearchIsTyped = false
    private var primeTask: Task<Void, Never>?
    private var placementTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var pending: MacChatFindMatch?
    /// The match a placement task is already working on; repeat registrations
    /// of the same row (every `updateNSView`) must not restart it.
    private var placing: MacChatFindMatch?
    /// Searchable ids of the previous search, oldest position first. Lets the
    /// cursor keep a position for a message that has left the transcript.
    private(set) var previousIDs: [String] = []
    private var restoreFocus: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isBound = false
    private weak var attachedEngine: ChatScrollEngine?

    init(
        environment: Environment = .empty,
        timing: Timing = Timing(),
        scroller: @escaping @MainActor (NSTextView, NSRange) -> Void = { MacChatFindScroll.reveal($1, in: $0) }
    ) {
        self.environment = environment
        self.timing = timing
        self.scroller = scroller
        registry.didRegister = { [weak self] id in self?.viewsChanged(messageID: id) }
    }

    var isAvailable: Bool { environment.isTranscriptShown() && environment.isChatRouteActive() }

    // MARK: wiring

    func bind(to appState: AppState, defaults: UserDefaults = .standard) {
        guard !isBound else { return }
        isBound = true
        environment = Environment(
            messages: { [weak appState] in appState?.messages ?? [] },
            hasEarlierMessages: { [weak appState] in appState?.canLoadEarlierMessagesForActiveConversation ?? false },
            isTranscriptShown: { [weak appState] in appState.map { $0.activeRoomSurface == nil } ?? false },
            isChatRouteActive: { Self.isChatRouteActive(defaults: defaults) }
        )
        observe(Self.routeChanges(defaults: defaults))
        observe(
            appState.$messages.dropFirst().map { _ in () }
                .merge(with: appState.$activeSessionId.dropFirst().map { _ in () })
                .merge(with: appState.$activeRoomSurface.dropFirst().map { _ in () })
                .eraseToAnyPublisher()
        )
    }

    static func isChatRouteActive(defaults: UserDefaults) -> Bool {
        MacChatRoute.isChatActive(tabRaw: defaults.string(forKey: MacSidebarState.tabDefaultsKey))
    }

    /// Fires when the sidebar destination key changes (and only then, not on
    /// every defaults write), so a tab switch closes the hidden bar.
    static func routeChanges(defaults: UserDefaults) -> AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .map { _ in defaults.string(forKey: MacSidebarState.tabDefaultsKey) }
            .prepend(defaults.string(forKey: MacSidebarState.tabDefaultsKey))
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Subscribes to transcript change signals. `@Published` emits in willSet,
    /// before the new value is stored, so the refresh hops to the next
    /// main-actor turn and only then reads the environment (availability, the
    /// loaded-only note, the messages). Bursts coalesce into one hop.
    func observe(_ changes: AnyPublisher<Void, Never>) {
        changes
            .sink { [weak self] in self?.scheduleTranscriptRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleTranscriptRefresh() {
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.changeTask = nil
            self.transcriptDidChange()
        }
    }

    /// Called by every row on appear (cheap): the engine that scrolls rows.
    func attach(engine: ChatScrollEngine) {
        guard attachedEngine !== engine else { return }
        attachedEngine = engine
        reveal = { [weak engine] id in engine?.explicitMessageRequested(id: id) }
    }

    // MARK: open and close

    func open(restoreFocus: (() -> Void)? = nil) {
        guard isAvailable else { return }
        if !isOpen {
            self.restoreFocus = restoreFocus
            isOpen = true
            showsLoadedOnlyNote = environment.hasEarlierMessages()
            primeCache()
            if MacChatFindMatcher.isSearchable(query) {
                scheduleSearch(after: .zero, keepIdentity: false, scroll: false)
            }
        }
        focusToken &+= 1
    }

    /// `restoringFocus: false` for a close the user did not ask for (the chat
    /// became unavailable or hidden): focus must not jump back into a hidden composer.
    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        searchTask?.cancel()
        searchIsPending = false
        primeTask?.cancel()
        cancelNavigation()
        state = MacChatFindState()
        registry.setContext(nil)
        lastAnnouncement = nil
        // Nothing searches while the bar is closed: drop the projected text of
        // the whole transcript and the old ids. Opening primes the cache again.
        cache.reset()
        previousIDs = []
        searchable = []
        // A hidden field must not keep first responder (it would swallow typing).
        if let window = field?.window, ownsResponder(window.firstResponder), !(window.firstResponder is ComposerTextView) {
            window.makeFirstResponder(nil)
        }
        let restore = restoreFocus
        restoreFocus = nil
        if restoringFocus { restore?() }
    }

    // MARK: navigation

    func next() { step { $0.next() } }
    func previous() { step { $0.previous() } }

    private func step(_ move: (inout MacChatFindState) -> Void) {
        guard isOpen else { return }
        if searchIsPending {
            searchTask?.cancel()
            if queuedSearchIsTyped {
                // Typed and pressed Return inside the debounce: apply the typed
                // query first and land on its selection instead of stepping.
                runSearch(keepIdentity: false, scroll: true)
                return
            }
            // A queued transcript refresh: apply it (same hit, no scroll), then step.
            runSearch(keepIdentity: true, scroll: false)
        }
        guard state.current != nil else { return }
        move(&state)
        applyHighlights()
        goToCurrent()
        announceSettled()
    }

    /// Speaks the count once a result has settled (typed query applied, or a
    /// step), never for intermediate keystrokes, and never twice in a row.
    private func announceSettled() {
        let label = MacChatFindLabel.text(query: query, state: state)
        guard !label.isEmpty else { lastAnnouncement = nil; return }
        let key = query + "\u{0}" + label
        guard key != lastAnnouncement else { return }
        lastAnnouncement = key
        announce(label)
    }

    // MARK: search

    private var searchIsPending = false

    private func queryChanged() {
        guard isOpen else { return }
        scheduleSearch(after: timing.debounce, keepIdentity: false, scroll: true)
    }

    /// Transcript changed (a message settled, an older page, a session switch).
    func transcriptDidChange() {
        guard isOpen else { return }
        if !isAvailable { close(restoringFocus: false); return }
        showsLoadedOnlyNote = environment.hasEarlierMessages()
        // A search already queued reads the latest transcript when it runs;
        // restarting it on every change would starve it while a reply streams.
        guard !searchIsPending else { return }
        scheduleSearch(after: timing.refresh, keepIdentity: true, scroll: false)
    }

    private func scheduleSearch(after delay: Duration, keepIdentity: Bool, scroll: Bool) {
        searchTask?.cancel()
        searchIsPending = true
        queuedSearchIsTyped = !keepIdentity
        searchTask = Task { [weak self] in
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.runSearch(keepIdentity: keepIdentity, scroll: scroll)
        }
    }

    private func runSearch(keepIdentity: Bool, scroll: Bool) {
        searchIsPending = false
        let entries = cache.entries(for: environment.messages())
        let ids = entries.map(\.id)
        let order = Self.order(current: ids, previous: previousIDs)
        previousIDs = ids
        searchable = Set(ids)
        let result = MacChatFindMatcher.matches(of: query, in: entries)
        let anchor: MacChatFindState.Anchor
        if let previous = state.current {
            anchor = keepIdentity
                ? .keeping(previous, order: order)
                : .near(messageID: previous.messageID, order: order)
        } else {
            anchor = .newest
        }
        state.replace(matches: result.matches, truncated: result.truncated, anchor: anchor)
        applyHighlights()
        if scroll { goToCurrent() }
        if state.current == nil { cancelNavigation() }
        if scroll { announceSettled() }
    }

    private func applyHighlights() {
        guard isOpen, MacChatFindMatcher.isSearchable(query) else {
            registry.setContext(nil)
            return
        }
        registry.setContext(.init(query: query, current: state.current, searchable: searchable))
    }

    private func primeCache() {
        primeTask?.cancel()
        let messages = environment.messages()
        primeTask = Task { [weak self] in await self?.cache.prime(messages) }
    }

    // MARK: scrolling

    private func goToCurrent() {
        cancelNavigation()
        guard let match = state.current else { return }
        if place(match) { return }
        // Not drawn yet. A mounted view that lacks the hit (a later block, or a
        // projection-only hit) still brings the message into view once.
        if let first = registry.views(for: match.messageID).first {
            scroller(first, NSRange(location: 0, length: min(1, (first.string as NSString).length)))
        }
        pending = match
        requestReveal(for: match, attempt: 0)
    }

    private func cancelNavigation() {
        pending = nil
        placing = nil
        placementTask?.cancel()
        revealTask?.cancel()
    }

    private func requestReveal(for match: MacChatFindMatch, attempt: Int) {
        // Ask the engine once per match. Re-asking is only worth it while no
        // view of the row is mounted (an estimated-height scroll can land
        // short); once a view is there but lacks the hit (an undrawn part of a
        // bounded message), re-yanking the row each retry would only fight the
        // reader.
        if attempt == 0 || registry.views(for: match.messageID).isEmpty {
            reveal(match.messageID)
        }
        let delay = timing.revealRetry
        revealTask = Task { [weak self] in
            // Weak across the sleep: a pending retry must not keep the controller alive.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard self.pending == match, self.state.current == match else {
                self.finish(match)
                return
            }
            // A registration may have been missed between retries.
            if self.place(match) {
                self.pending = nil
                return
            }
            if attempt + 1 >= self.timing.maxRevealRetries {
                // Bounded: the hit stays counted and current, nothing more happens.
                self.pending = nil
                return
            }
            self.requestReveal(for: match, attempt: attempt + 1)
        }
    }

    /// A row's view mounted or updated (fires on every `updateNSView`): cheap,
    /// idempotent, and only acts when it completes the pending hit.
    private func viewsChanged(messageID: String) {
        guard let match = pending, match.messageID == messageID, placing != match,
              registry.target(messageID: messageID, ordinal: match.ordinal, query: query) != nil else { return }
        placing = match
        revealTask?.cancel()
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            guard let self else { return }
            for delay in self.timing.placement {
                if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
                guard !Task.isCancelled else { return }
                guard self.state.current == match else {
                    self.finish(match)
                    return
                }
                self.place(match)
            }
            self.finish(match)
        }
    }

    /// Navigation to `match` is over (placed, exhausted or superseded).
    private func finish(_ match: MacChatFindMatch) {
        if pending == match { pending = nil }
        if placing == match { placing = nil }
    }

    /// Scrolls to the hit inside its mounted view. False when no mounted view
    /// draws it.
    @discardableResult
    private func place(_ match: MacChatFindMatch) -> Bool {
        guard let spot = registry.target(messageID: match.messageID, ordinal: match.ordinal, query: query) else { return false }
        scroller(spot.view, spot.range)
        return true
    }

    /// Position of every message id: the current transcript's order, with ids
    /// that have left it kept at their old relative position (after the nearest
    /// earlier id that stayed), so a cursor on a removed message still maps to
    /// its neighbours. Disjoint transcripts (a session switch) keep no old ids.
    static func order(current: [String], previous: [String]) -> [String: Int] {
        let kept = Set(current)
        var merged: [String] = []
        if previous.contains(where: kept.contains) {
            var leading: [String] = []
            var after: [String: [String]] = [:]
            var last: String?
            for id in previous {
                if kept.contains(id) { last = id; continue }
                if let last { after[last, default: []].append(id) } else { leading.append(id) }
            }
            merged = leading
            for id in current {
                merged.append(id)
                if let removed = after.removeValue(forKey: id) { merged.append(contentsOf: removed) }
            }
        } else {
            merged = current
        }
        return Dictionary(
            merged.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: responders

    /// True for responders that count as "in the chat" for Cmd-F routing.
    func ownsResponder(_ responder: NSResponder?) -> Bool {
        if responder is ComposerTextView { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field,
           (editor.delegate as AnyObject?) === field { return true }
        return registry.contains(responder)
    }

    /// Cached projections, for tests.
    var projectionCacheCount: Int { cache.count }

    /// Waits for the queued search, cache fill and placement. For tests.
    func settled() async {
        await changeTask?.value
        await searchTask?.value
        await primeTask?.value
        await placementTask?.value
    }
}

/// The find controller of each main chat window.
@MainActor
enum MacChatFindControllers {
    private static let table = NSMapTable<NSWindow, MacChatFindController>(
        keyOptions: .weakMemory,
        valueOptions: .weakMemory
    )

    static func register(_ controller: MacChatFindController, in window: NSWindow) {
        table.setObject(controller, forKey: window)
    }

    static func controller(for window: NSWindow?) -> MacChatFindController? {
        guard let window else { return nil }
        return table.object(forKey: window)
    }
}
