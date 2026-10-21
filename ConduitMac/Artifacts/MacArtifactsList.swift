// Mac twin of V2ArtifactsViews.swift ArtifactsList; keep in sync
import AppKit
import ImageIO
import SwiftUI

// What a profile's chats produced, as a Mac list (D26): kind chips, day sections, a 3-column tile
// grid for pictures and videos, rows for the rest, paged from the host. Upstream's list is a
// `private struct` in a V2-shell file, so it cannot be used here. This twin differs on purpose:
//   - no V2Backdrop, no `.searchable` (D6: a second one crashes NSToolbar) and no `.refreshable`.
//     The search text comes in as `query` from the pane's `MacSearchPill`; Refresh is in the
//     More menu.
//   - Mac density (`MacSidebarMetrics`), click instead of tap, no haptics, no Share item.
//   - Open reveals the downloaded file in Finder (`MediaPreviewPresenter`, quarantined first);
//     a page opens `HTMLPreviewSheet` in a sheet.
//   - The loading state is a plain value (`MacArtifactsListState`) so its paging rules are tested
//     without a view.
//   - The load also runs again when the plugin's capability report lands after the pane opened
//     (upstream's list waits for the next key change).

/// The list's loading state. Each method is one step of upstream's `reload()` / `loadMore()`;
/// the view does the awaiting between `begin...` and `finish...`.
struct MacArtifactsListState {
    /// Every row read so far, files the host no longer has included (see `visibleItems`).
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
    /// on a new cursor is not turned away by the old read still unwinding.
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

    /// A file the host no longer has. A link has no file to miss (upstream #1068 makes the model
    /// say so; this keeps the Mac list right until that merge step lands).
    static func isMissing(_ item: ArtifactItem) -> Bool {
        item.source != .link && !item.exists
    }

    /// The rows to draw. An older plugin lists missing files whatever it was asked.
    func visibleItems(showMissing: Bool) -> [ArtifactItem] {
        showMissing ? items : items.filter { !MacArtifactsListState.isMissing($0) }
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
        if loadingBefore == request.before { loadingBefore = nil }
        switch outcome {
        case .cancelled:
            return
        case .page(let page):
            guard request.ticket == generation else { return }
            items = ArtifactsClient.merged(items, with: page.items)
            nextBefore = page.nextBefore
        case .failed(let message):
            // The end of the list offers Try Again.
            guard request.ticket == generation else { return }
            failure = message
        }
    }
}

/// Where the list reads artifacts from. The defaults read the app. A test swaps them: the plugin
/// report on `AppState` is `private(set)` and its dashboard bridge needs a live host.
struct MacArtifactsSource {
    var supported: @MainActor (AppState) -> Bool = { $0.supportsArtifacts }
    var client: @MainActor (AppState) -> ArtifactsClient = { $0.artifactsClient }
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

struct MacArtifactsList: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macArtifactsSource) private var source
    let scope: ArtifactScope
    /// A chat's own list: rows give the time rather than the chat's name.
    let chatIsOpen: Bool
    /// The pane's search text (the chat's sheet has none).
    let query: String
    let showInChat: (ArtifactItem) -> Void

    /// Upstream's key (`ArtifactsClient.showMissingKey` once that merge step lands), so the
    /// setting is one setting.
    static let showMissingKey = "artifacts.showMissing"
    static let showMissingDefault = false
    @AppStorage(MacArtifactsList.showMissingKey) private var showMissing = MacArtifactsList.showMissingDefault
    @State private var filter: ArtifactFilter = .all
    @State private var state = MacArtifactsListState()
    @State private var openingID: String?
    @State private var page: OpenPage?
    @State private var missing: ArtifactItem?
    /// The open alert is for a file too big to download, not a gone one.
    @State private var missingIsTooLarge = false
    /// Cancelled when the list goes, so a slow fetch can't present a viewer over whatever the
    /// user moved on to.
    @State private var openTask: Task<Void, Never>?

    init(scope: ArtifactScope, chatIsOpen: Bool, query: String = "", showInChat: @escaping (ArtifactItem) -> Void) {
        self.scope = scope
        self.chatIsOpen = chatIsOpen
        self.query = query
        self.showInChat = showInChat
    }

    private struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    /// What reads the host again: the list's key, or the host starting to offer artifacts.
    private struct LoadID: Equatable {
        let key: ArtifactsListKey
        let supported: Bool
    }

    private var currentKey: ArtifactsListKey {
        ArtifactsListKey(dashboard: appState.activeDashboardID, profile: appState.activeProfile, filter: filter,
                         query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                controls
                    .padding(.bottom, 6)
                content
            }
            .padding(.bottom, 24)
        }
        .task(id: LoadID(key: currentKey, supported: source.supported(appState))) {
            // Typing settles before the host is asked.
            if state.loadedKey != nil, currentKey.query != state.loadedKey?.query {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
        .sheet(item: $page) { page in
            HTMLPreviewSheet(name: page.name, html: page.html)
                .macFormSheetSize(minWidth: 560, idealWidth: 800, minHeight: 420, idealHeight: 640)
        }
        .onDisappear { openTask?.cancel() }
        .alert(
            missingIsTooLarge ? Text("Too large to open on this Mac") : Text("This file is no longer on your Hermes host."),
            isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })
        ) {
            Button("OK", role: .cancel) { missing = nil }
        } message: {
            Text(verbatim: missing?.path ?? "")
        }
    }

    // MARK: - Chips and More

    private var controls: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ArtifactFilter.allCases) { option in
                        chip(option)
                    }
                }
                .padding(.vertical, 4)
            }
            .macTrailingFade()
            if source.supported(appState) {
                moreMenu
            }
        }
    }

    private func chip(_ option: ArtifactFilter) -> some View {
        let isOn = option == filter
        return Button {
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { filter = option }
        } label: {
            Text(option.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.conduitBackgroundColor : .secondary)
                .padding(.horizontal, MacSidebarMetrics.chipPadding)
                .frame(height: MacSidebarMetrics.chipHeight)
                .background(isOn ? Color.conduitAccent : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Show Missing Files", isOn: $showMissing)
            Divider()
            Button("Refresh") { Task { await reload() } }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: MacSidebarMetrics.glyphSize + 1, weight: .semibold))
                .frame(width: MacControlHeight.compact, height: MacControlHeight.compact)
        }
        .buttonStyle(.plain)
        .conduitGlassControl(cornerRadius: MacSidebarMetrics.controlRadius)
        .accessibilityLabel("More")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let visible = state.visibleItems(showMissing: showMissing)
        if !source.supported(appState) {
            unavailable(
                title: Text("Update the Conduit plugin"),
                detail: Text("Update the Conduit plugin on your Hermes host to see artifacts here. Settings › Conduit plugin can update it."),
                symbol: "arrow.down.circle"
            )
        } else if visible.isEmpty, state.isLoading || state.loadedKey != currentKey {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if visible.isEmpty, let failure = state.failure {
            unavailable(title: Text("Artifacts couldn't load"), detail: Text(verbatim: failure),
                        symbol: "exclamationmark.triangle", retry: true)
        } else if visible.isEmpty, state.nextBefore == nil {
            // Hidden missing files may be all there is, so the way back is offered under either
            // message.
            let hiddenNote = showMissing ? Text(verbatim: "")
                : Text(verbatim: " ") + Text("Files no longer on your Hermes host are hidden.")
            if currentKey.query.isEmpty && filter == .all {
                unavailable(
                    title: Text("No Artifacts Yet"),
                    detail: Text("Files Hermes sends or writes, pages it draws, files you attach and links show up here.")
                        + hiddenNote,
                    symbol: "square.grid.2x2",
                    showMissingAction: !showMissing
                )
            } else {
                unavailable(title: Text("No Results"), detail: Text("Nothing here matches.") + hiddenNote,
                            symbol: "magnifyingglass", showMissingAction: !showMissing)
            }
        } else {
            ForEach(ArtifactsClient.days(visible)) { day in
                section(day.day, items: day.items)
            }
            // The last filter's rows, dimmed until the new ones arrive.
            .opacity(state.loadedKey == currentKey ? 1 : 0.45)
            .allowsHitTesting(state.loadedKey == currentKey)
            if state.nextBefore != nil {
                if state.failure != nil {
                    Button("Try Again") {
                        state.failure = nil
                        Task { await loadMore() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    if visible.isEmpty, !showMissing {
                        // A history of deleted files can take a few pages to get past.
                        VStack(spacing: 8) {
                            Text("Files no longer on your Hermes host are hidden.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Show Missing Files") { showMissing = true }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    // Reaching the end reads the next page.
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .task(id: state.nextBefore) { await loadMore() }
                }
            }
        }
    }

    private func unavailable(title: Text, detail: Text, symbol: String, retry: Bool = false,
                             showMissingAction: Bool = false) -> some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: symbol) }
        } description: {
            detail
        } actions: {
            if retry {
                Button("Try Again") { Task { await reload() } }
            }
            if showMissingAction {
                Button("Show Missing Files") { showMissing = true }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @ViewBuilder
    private func section(_ day: Date, items: [ArtifactItem]) -> some View {
        Text(Self.dayTitle(day))
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
        let visual = items.filter(\.isVisual)
        if !visual.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(visual) { item in
                    tile(item)
                }
            }
            .padding(.bottom, 8)
        }
        VStack(spacing: 6) {
            ForEach(items.filter { !$0.isVisual }) { item in
                row(item)
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return AppLocalization.string("Today") }
        if calendar.isDateInYesterday(day) { return AppLocalization.string("Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(sameYear
            ? .dateTime.weekday(.wide).month(.wide).day()
            : .dateTime.month(.wide).day().year())
    }

    // MARK: - Items

    private func tile(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            MacArtifactThumbnail(item: item, resolver: appState.gatewayMediaResolver,
                                 dashboard: appState.activeDashboardID, profile: appState.activeProfile)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if openingID == item.id {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
                }
                .opacity(MacArtifactsListState.isMissing(item) ? 0.45 : 1)
                .overlay(alignment: .topLeading) {
                    // Over the dimming, which alone reads as a dark picture, and clear of the
                    // name along the bottom.
                    if MacArtifactsListState.isMissing(item) {
                        Label("Missing", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(5)
                            // The tile's label says it already.
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: accessibilityName(item)))
    }

    private func row(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 10) {
                MacArtifactIcon(kind: item.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: detail(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if openingID == item.id {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, MacSidebarMetrics.sessionCardPaddingH)
            .padding(.vertical, MacSidebarMetrics.sessionCardPaddingV)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: MacSidebarMetrics.sessionCardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacSidebarMetrics.sessionCardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .opacity(MacArtifactsListState.isMissing(item) ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: MacSidebarMetrics.sessionCardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { menu(item) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button {
            showInChat(item)
        } label: {
            Label("Show in Chat", systemImage: "text.bubble")
        }
        if let url = item.url {
            Button {
                Self.copyLink(url)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        } else if let path = item.path {
            Button {
                Self.copyPath(path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    private func detail(_ item: ArtifactItem) -> String {
        var parts = [Self.kindLabel(item.kind)]
        if item.source == .attached { parts.append(AppLocalization.string("You sent")) }
        if MacArtifactsListState.isMissing(item) {
            parts.append(AppLocalization.string("No longer on the host"))
        } else if let size = item.size, item.kind != .link {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let host = item.host, item.kind == .link {
            parts.append(host)
        }
        if chatIsOpen {
            parts.append(item.date.formatted(date: .omitted, time: .shortened))
        } else if !item.sessionTitle.isEmpty {
            parts.append(item.sessionTitle)
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityName(_ item: ArtifactItem) -> String {
        [item.name, Self.kindLabel(item.kind), MacArtifactsListState.isMissing(item) ? AppLocalization.string("No longer on the host") : "",
         chatIsOpen ? "" : item.sessionTitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func kindLabel(_ kind: ArtifactItem.Kind) -> String {
        switch kind {
        case .image: return AppLocalization.string("Image")
        case .video: return AppLocalization.string("Video")
        case .audio: return AppLocalization.string("Audio")
        case .page: return AppLocalization.string("Page")
        case .document: return AppLocalization.string("Document")
        case .file: return AppLocalization.string("File")
        case .link: return AppLocalization.string("Link")
        }
    }

    // MARK: - Copy

    /// The address as a URL and as text, so a text field takes it too.
    static func copyLink(_ url: URL, to board: NSPasteboard = .general) {
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
    }

    static func copyPath(_ path: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(path, forType: .string)
    }

    // MARK: - Opening

    static func openAction(for item: ArtifactItem) -> MacArtifactOpen? {
        if let url = item.url, item.path == nil { return .link(url) }
        guard let path = item.path else { return nil }
        guard !MacArtifactsListState.isMissing(item) else { return .missing }
        return item.kind == .page ? .page(path: path) : .file(path: path)
    }

    private func open(_ item: ArtifactItem) {
        guard let action = Self.openAction(for: item) else { return }
        if case .link(let url) = action {
            openURL(url)
            return
        }
        guard openingID == nil else { return }
        let resolver = appState.gatewayMediaResolver
        switch action {
        case .link:
            break   // opened above
        case .missing:
            missingIsTooLarge = false
            missing = item
        case .page(let path):
            openingID = item.id
            openTask = Task { @MainActor in
                defer { openingID = nil }
                guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
                guard let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) else {
                    openFailed(item)
                    return
                }
                page = OpenPage(name: item.name, html: html)
            }
        case .file(let path):
            openingID = item.id
            openTask = Task { @MainActor in
                defer { openingID = nil }
                switch await resolver.file(for: path) {
                case .downloaded(let download):
                    guard !Task.isCancelled else {
                        MediaPreviewPresenter.removeDirectory(download.directory)
                        return
                    }
                    if MediaPreviewPresenter.shared.present(downloaded: download) { return }
                case .tooLarge:
                    openFailed(item, tooLarge: true)
                    return
                case .unavailable:
                    break
                }
                // A cancelled download reads as unavailable; no fallback for a list that has gone.
                guard !Task.isCancelled else { return }
                guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
                guard await MediaPreviewPresenter.shared.present(dataURL: dataURL, filename: item.name) else {
                    openFailed(item)
                    return
                }
            }
        }
    }

    private func openFailed(_ item: ArtifactItem, tooLarge: Bool = false) {
        guard !Task.isCancelled else { return }
        missingIsTooLarge = tooLarge
        missing = item
    }

    // MARK: - Loading

    private func reload() async {
        guard source.supported(appState) else { return }
        let key = currentKey
        let ticket = state.beginReload(key)
        let outcome: MacArtifactsListState.Outcome
        do {
            outcome = .page(try await source.client(appState).page(
                profile: key.profile, sessionIDs: scope.sessionIDs, filter: key.filter, query: key.query
            ))
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(UserFacingError.message(for: error))
        }
        state.finishReload(outcome, key: key, ticket: ticket)
    }

    private func loadMore() async {
        guard let request = state.beginNextPage(current: currentKey) else { return }
        let outcome: MacArtifactsListState.Outcome
        do {
            outcome = .page(try await source.client(appState).page(
                profile: request.key.profile, sessionIDs: scope.sessionIDs, filter: request.key.filter,
                query: request.key.query, before: request.before
            ))
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(UserFacingError.message(for: error))
        }
        state.finishNextPage(outcome, request: request)
    }
}

/// A row's round-cornered kind glyph.
private struct MacArtifactIcon: View {
    let kind: ArtifactItem.Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        case .page: return "chart.xyaxis.line"
        case .document: return "doc.text"
        case .file: return "doc"
        case .link: return "link"
        }
    }

    private var tint: Color {
        switch kind {
        case .page: return .conduitAccent
        case .document, .file: return .red
        case .audio: return .blue
        case .image, .video: return .purple
        case .link: return .secondary
        }
    }
}

/// An image's thumbnail (read from the host and kept small), or a video's play glyph, in a grid
/// tile.
private struct MacArtifactThumbnail: View {
    let item: ArtifactItem
    let resolver: GatewayMediaDataURLResolver
    let dashboard: UUID?
    let profile: String
    @State private var image: NSImage?

    private var cacheKey: NSString {
        ArtifactsListKey.thumbnailCacheKey(dashboard: dashboard, profile: profile, path: item.path ?? "")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.primary.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholderGlyph
            }
            if image == nil {
                Text(verbatim: item.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(7)
            }
        }
        .task(id: cacheKey) { await loadThumbnail() }
    }

    private var placeholderGlyph: some View {
        Image(systemName: item.kind == .video ? "play.fill" : "photo")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadThumbnail() async {
        guard item.kind == .image else { return }
        if item.path == nil, let url = item.url {
            // A web image: fetched and downsampled within bounds, like the same picture in the chat.
            if let cached = BoundedRemoteImage.cachedImage(url, maxPixelSize: 360) {
                image = cached
                return
            }
            image = nil
            guard case .image(let thumbnail) = await BoundedRemoteImage.load(url, maxPixelSize: 360),
                  !Task.isCancelled else { return }
            image = thumbnail
            return
        }
        guard item.exists, let path = item.path else { return }
        if let cached = MacArtifactThumbnailCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }
        image = nil
        guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
        let thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let data = DataURLLimits.decodeBase64DataURL(dataURL),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
        guard let thumbnail, !Task.isCancelled else { return }
        MacArtifactThumbnailCache.shared.setObject(thumbnail, forKey: cacheKey)
        image = thumbnail
    }
}

/// Thumbnails by host path, so scrolling back doesn't read them again.
private enum MacArtifactThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
}
