import Combine
import SwiftUI

// The open chat's artifacts for the toolbar's Artifacts button and the side panel (D33). The
// store reads the whole list of the main window's open chat (a few pages at most) when the chat
// changes and again when a turn ends, because the host lists what Hermes has saved. No upstream
// counterpart.

/// What the panel's list was read for: one chat, by every id it is known by, on one server.
struct MacChatArtifactsPanelKey: Equatable {
    let dashboard: UUID?
    let profile: String
    /// Sorted, never empty.
    let sessionIDs: [String]
    let showMissing: Bool

    /// The same chat on the same server: it can gain an id (a resume records its durable one) or
    /// change the missing-files setting, and its rows stay up while it is read again.
    func isSameChat(as other: MacChatArtifactsPanelKey?) -> Bool {
        guard let other, other.dashboard == dashboard, other.profile == profile else { return false }
        return !Set(other.sessionIDs).isDisjoint(with: sessionIDs)
    }
}

/// The panel's loading state, a plain value so its rules are tested without a view or a host.
struct MacChatArtifactsPanelState {
    enum Outcome: Equatable {
        /// Every row read, and whether the host had more than the panel reads.
        case items([ArtifactItem], truncated: Bool)
        case cancelled
        case failed(String)
    }

    private(set) var items: [ArtifactItem] = []
    private(set) var loadedKey: MacChatArtifactsPanelKey?
    private(set) var isLoading = false
    /// The first read of `loadedKey` failed. A failed refresh keeps the list it refreshed.
    private(set) var failure: String?
    /// The host listed more than `MacChatArtifactsPanelStore.maxPages` pages.
    private(set) var isTruncated = false
    private(set) var generation = 0

    /// The rows to draw for `key`: its own, or its chat's while that chat is read again. Never
    /// another chat's.
    func rows(for key: MacChatArtifactsPanelKey?) -> [ArtifactItem] {
        guard let key else { return [] }
        if loadedKey == key || (isLoading && key.isSameChat(as: loadedKey)) { return items }
        return []
    }

    /// The button's number; nil while it is not known yet.
    func count(for key: MacChatArtifactsPanelKey?) -> Int? {
        guard let key else { return nil }
        if loadedKey == key || (isLoading && key.isSameChat(as: loadedKey)) { return items.count }
        return nil
    }

    /// Whether the toolbar shows the button: the chat has an artifact. While another chat's list
    /// is read, a button that was shown stays (without a number), so it does not leave and come
    /// back between two chats that both have artifacts.
    func showsButton(for key: MacChatArtifactsPanelKey?) -> Bool {
        guard let key else { return false }
        if loadedKey == key { return !items.isEmpty }
        return isLoading && !items.isEmpty && loadedKey?.dashboard == key.dashboard
    }

    /// Starts a read; its result must carry the returned ticket.
    mutating func beginReload() -> Int {
        generation &+= 1
        isLoading = true
        return generation
    }

    mutating func finishReload(_ outcome: Outcome, key: MacChatArtifactsPanelKey, ticket: Int) {
        guard ticket == generation else { return }
        isLoading = false
        switch outcome {
        case .cancelled:
            return
        case .items(let read, let truncated):
            items = read
            isTruncated = truncated
            failure = nil
            loadedKey = key
        case .failed(let message):
            guard loadedKey != key else { return }
            items = []
            isTruncated = false
            failure = message
            loadedKey = key
        }
    }

    /// No chat to list: nothing shown, and a read in flight is dropped.
    mutating func clear() {
        generation &+= 1
        items = []
        loadedKey = nil
        isLoading = false
        failure = nil
        isTruncated = false
    }
}

@MainActor
final class MacChatArtifactsPanelStore: ObservableObject {
    static let shared = MacChatArtifactsPanelStore()
    /// Whether the panel is open. One setting for every chat; off by default.
    static let openDefaultsKey = "conduit.mac.chatArtifactsPanelOpen"
    /// Pages of `ArtifactsClient.pageSize` read at most: 600 artifacts. Show as List reads the rest.
    static let maxPages = 10
    /// Wait after a turn ends before reading, so the host has saved the turn's messages.
    static let turnEndDelay: Duration = .seconds(1)

    @Published private(set) var state = MacChatArtifactsPanelState()
    /// The open chat's key; nil with no chat that has a row of its own, in a room, or on a host
    /// whose plugin lists no artifacts.
    @Published private(set) var key: MacChatArtifactsPanelKey?
    @Published private(set) var isOpen: Bool

    private let defaults: UserDefaults
    private let source: MacArtifactsSource
    /// Reads the open chat's key; nil reads `key(appState:source:defaults:)`. A test swaps it: an
    /// isolated `AppState` has no open chat with a row of its own.
    private let readKey: (@MainActor (AppState) -> MacChatArtifactsPanelKey?)?
    private weak var appState: AppState?
    private var bindings = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var turnEndTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, source: MacArtifactsSource = MacArtifactsSource(),
         readKey: (@MainActor (AppState) -> MacChatArtifactsPanelKey?)? = nil) {
        self.defaults = defaults
        self.source = source
        self.readKey = readKey
        isOpen = defaults.bool(forKey: Self.openDefaultsKey)
    }

    var showsButton: Bool { state.showsButton(for: key) }
    var count: Int? { state.count(for: key) }
    var items: [ArtifactItem] { state.rows(for: key) }
    var showsPanel: Bool { isOpen && showsButton }
    /// The ids the open chat is known by, for Show as List.
    var sessionIDs: [String] { key?.sessionIDs ?? [] }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        defaults.set(open, forKey: Self.openDefaultsKey)
    }

    func toggle() { setOpen(!isOpen) }

    /// Follows the main window's open chat. Bound once, by the main window.
    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        self.appState = appState
        // willSet sinks: the key is read on a later main-queue turn, when the values are current.
        // A streaming reply publishes often; the key is cached on AppState and cheap to read.
        appState.objectWillChange.map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                .map { _ in () })
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.refreshKey() }
            .store(in: &bindings)
        appState.$turnState
            .map(\.isRunning)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] running in
                if running {
                    self?.turnEndTask?.cancel()
                } else {
                    self?.scheduleTurnEndReload()
                }
            }
            .store(in: &bindings)
        refreshKey()
    }

    /// Reads the open chat's key; a new key reads its list.
    func refreshKey() {
        guard let appState else { return }
        let next: MacChatArtifactsPanelKey?
        if let readKey {
            next = readKey(appState)
        } else {
            next = Self.key(appState: appState, source: source, defaults: defaults)
        }
        guard next != key else { return }
        key = next
        reload()
    }

    static func key(appState: AppState, source: MacArtifactsSource, defaults: UserDefaults) -> MacChatArtifactsPanelKey? {
        guard source.supported(appState), appState.activeRoomSurface == nil else { return nil }
        let ids = appState.activeChatArtifactSessionIDs
        // An empty id list would read every chat in the profile.
        guard !ids.isEmpty else { return nil }
        return MacChatArtifactsPanelKey(dashboard: source.dashboardID(appState), profile: appState.activeProfile,
                                        sessionIDs: ids.sorted(),
                                        showMissing: defaults.bool(forKey: ArtifactsClient.showMissingKey))
    }

    /// Reads the open chat's list again (a new key, a finished turn, Refresh).
    func reload() {
        loadTask?.cancel()
        guard let key, let appState else {
            state.clear()
            return
        }
        let ticket = state.beginReload()
        let client = source.client(appState)
        loadTask = Task { [weak self] in
            let outcome = await Self.read(key: key, client: client, maxPages: Self.maxPages)
            self?.state.finishReload(outcome, key: key, ticket: ticket)
        }
    }

    private func scheduleTurnEndReload() {
        turnEndTask?.cancel()
        turnEndTask = Task { [weak self] in
            try? await Task.sleep(for: Self.turnEndDelay)
            guard !Task.isCancelled, let self else { return }
            // A new key reads its list already.
            let old = self.key
            self.refreshKey()
            if self.key == old { self.reload() }
        }
    }

    /// Every page of `key`'s list, up to `maxPages`.
    static func read(key: MacChatArtifactsPanelKey, client: ArtifactsClient, maxPages: Int) async
        -> MacChatArtifactsPanelState.Outcome {
        var items: [ArtifactItem] = []
        var before: Int?
        do {
            for _ in 0..<maxPages {
                let page = try await client.page(profile: key.profile, sessionIDs: key.sessionIDs,
                                                 showMissing: key.showMissing, before: before)
                guard !Task.isCancelled else { return .cancelled }
                items = ArtifactsClient.merged(items, with: page.items)
                // A host that answers with the cursor it was asked for has nothing older.
                guard let next = page.nextBefore, next != before else { return .items(items, truncated: false) }
                before = next
            }
            return .items(items, truncated: true)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
    }
}
