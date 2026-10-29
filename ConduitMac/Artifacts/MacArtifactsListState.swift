import SwiftUI

// The Mac-only parts of the Artifacts list (D26): its loading state, its test seam and the Open
// decision. None of these has an upstream counterpart (upstream keeps this as `@State` inside the
// private `ArtifactsList`), so this file carries no `keep in sync` marker. The view that maps to
// upstream is `MacArtifactsList.swift`.

/// The list's loading state. Each method is one step of upstream's `reload()` / `loadMore()`;
/// the view does the awaiting between `begin...` and `finish...`.
struct MacArtifactsListState {
    /// Every row read so far. The host (or, for an older plugin, `ArtifactsClient.parse`) already
    /// left out the files it no longer has when the list asks to hide them.
    var items: [ArtifactItem] = []
    /// Nil once the history is read to its start.
    var nextBefore: Int?
    /// What the rows were read for.
    var loadedKey: ArtifactsListKey?
    /// A reload is reading. A page read does not set this: that swapped a list with nothing to
    /// show for the centred spinner, which unmounted the pager and cancelled its read (upstream
    /// #1068).
    var isLoading = false
    /// The cursor the next page is being read from. A cursor, not a flag, so a pager restarted
    /// on a new cursor is not turned away by the old read still unwinding. A reload drops it: the
    /// read in flight is stale (its ticket no longer matches), and a reload that returns the same
    /// cursor must be able to read it again.
    var loadingBefore: Int?
    var failure: String?
    private(set) var generation = 0

    enum Outcome {
        case page(ArtifactPage)
        case cancelled
        case failed(String)
    }

    /// A page read in flight: its cursor, the key it was read for and the ticket it must present.
    struct PageRequest: Equatable {
        let before: Int
        let key: ArtifactsListKey
        let ticket: Int
    }

    /// The rows to draw for `current`: none while they are another server's, which the list shows
    /// for one pass between a dashboard change and `beginReload` clearing them.
    func rows(for current: ArtifactsListKey) -> [ArtifactItem] {
        current.showsRows(of: loadedKey) ? items : []
    }

    /// Starts reading `key`; the result carries the returned ticket.
    mutating func beginReload(_ key: ArtifactsListKey) -> Int {
        generation &+= 1
        if !key.showsRows(of: loadedKey) {
            // Another server's list isn't shown, even dimmed, under this one.
            items = []
            nextBefore = nil
            failure = nil
            loadedKey = nil
        }
        loadingBefore = nil
        isLoading = true
        return generation
    }

    mutating func finishReload(_ outcome: Outcome, key: ArtifactsListKey, ticket: Int) {
        if ticket == generation { isLoading = false }
        switch outcome {
        case .cancelled:
            return
        case .page(let page):
            guard ticket == generation else { return }
            items = page.items
            nextBefore = page.nextBefore
            failure = nil
            loadedKey = key
        case .failed(let message):
            // A failed refresh keeps the list it was refreshing (and the end of it keeps paging).
            guard ticket == generation, loadedKey != key else { return }
            failure = message
            items = []
            nextBefore = nil
            loadedKey = key
        }
    }

    /// The next page to read, or nil when there is none to read now: no cursor, rows read for
    /// another key, a reload reading, or this cursor already being read.
    mutating func beginNextPage(current: ArtifactsListKey) -> PageRequest? {
        guard let before = nextBefore, let key = loadedKey, key == current, !isLoading,
              loadingBefore != before else { return nil }
        loadingBefore = before
        return PageRequest(before: before, key: key, ticket: generation)
    }

    mutating func finishNextPage(_ outcome: Outcome, request: PageRequest) {
        // Only the read of the current list clears its cursor: a stale read must not clear the
        // cursor of the read that replaced it.
        if request.ticket == generation, loadingBefore == request.before { loadingBefore = nil }
        switch outcome {
        case .cancelled:
            return
        case .page(let page):
            guard request.ticket == generation else { return }
            items = ArtifactsClient.merged(items, with: page.items)
            // A host that answers with the cursor it was just asked for has nothing older: the
            // list ends there, else the pager would wait on a cursor that never changes.
            nextBefore = page.nextBefore == request.before ? nil : page.nextBefore
        case .failed(let message):
            // The end of the list offers Try Again.
            guard request.ticket == generation else { return }
            failure = message
        }
    }
}

/// What reads host files for one open or one thumbnail. Built once, as upstream's list captures
/// `AppState.gatewayMediaResolver` once: that resolver is scoped to the dashboard it was built
/// for (upstream #1023) and refuses to read after a switch, where a resolver fetched again for
/// each read would read from the new server.
struct MacArtifactsReader {
    /// A host file as a data URL (a page, a picture, the fallback for a file).
    var dataURL: @MainActor (String) async -> String?
    /// A host file downloaded to disk.
    var file: @MainActor (String) async -> GatewayMediaFileResult
}

/// Where the list reads from. The defaults read the app. A test swaps them: the plugin report and
/// the saved dashboards on `AppState` are `private(set)`, its dashboard bridge needs a live host,
/// and `MediaPreviewPresenter` would open Finder.
struct MacArtifactsSource {
    var supported: @MainActor (AppState) -> Bool = { $0.supportsArtifacts }
    var client: @MainActor (AppState) -> ArtifactsClient = { $0.artifactsClient }
    var dashboardID: @MainActor (AppState) -> UUID? = { $0.activeDashboardID }
    var reader: @MainActor (AppState) -> MacArtifactsReader = { appState in
        let resolver = appState.gatewayMediaResolver
        return MacArtifactsReader(dataURL: { await resolver.dataURL(for: $0) }, file: { await resolver.file(for: $0) })
    }
    /// Shows a downloaded file (`MediaPreviewPresenter.present(downloaded:)`).
    var present: @MainActor (DashboardDownloadedFile) -> Bool = { MediaPreviewPresenter.shared.present(downloaded: $0) }
    /// Shows a file from its data URL (`MediaPreviewPresenter.present(dataURL:filename:)`).
    var presentDataURL: @MainActor (String, String) async -> Bool = {
        await MediaPreviewPresenter.shared.present(dataURL: $0, filename: $1)
    }
}

private struct MacArtifactsSourceKey: EnvironmentKey {
    static let defaultValue = MacArtifactsSource()
}

extension EnvironmentValues {
    var macArtifactsSource: MacArtifactsSource {
        get { self[MacArtifactsSourceKey.self] }
        set { self[MacArtifactsSourceKey.self] = newValue }
    }
}

/// What Open does for an item.
enum MacArtifactOpen: Equatable {
    case link(URL)
    /// The host no longer has the file.
    case missing
    case page(path: String)
    case file(path: String)
}
