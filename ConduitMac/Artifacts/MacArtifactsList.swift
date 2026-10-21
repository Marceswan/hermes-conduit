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
//     without a view; with `MacArtifactsSource` and `MacArtifactOpen` it is in
//     MacArtifactsListState.swift (no upstream counterpart).
//   - The load also runs again when the plugin's capability report lands after the pane opened
//     (upstream's list waits for the next key change).
//   - The pager also restarts when a reload ends, and a page that answers with the cursor it was
//     asked for ends the list (upstream's pager waits on an id that did not change).
//   - No row of another server is drawn while that server's list loads, and a dashboard change
//     cancels an open in flight (upstream draws the old rows dimmed for one pass).
//   - A page that cannot be drawn in the sheet (no data URL, over the size limit, not UTF-8)
//     opens as a file: download, quarantine, Finder (upstream ends without a message, or says the
//     file is gone).

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

    @AppStorage(ArtifactsClient.showMissingKey) private var showMissing = false
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
        ArtifactsListKey(dashboard: source.dashboardID(appState), profile: appState.activeProfile, filter: filter,
                         query: query.trimmingCharacters(in: .whitespacesAndNewlines), showMissing: showMissing)
    }

    /// What restarts the pager: a new cursor, or a reload starting (`generation`) or ending
    /// (`isLoading`). Without them, a page read that a reload made stale never restarts when the
    /// reload returns the same cursor: not when it ends before the view draws (generation), not
    /// when it takes longer (isLoading).
    private struct PagerID: Equatable {
        let nextBefore: Int?
        let generation: Int
        let isLoading: Bool
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
        .onChange(of: currentKey.dashboard) { _, _ in
            // A download or page read for the old server must not open its file under the new one.
            openTask?.cancel()
            openingID = nil
        }
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
        let visible = state.rows(for: currentKey)
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
                        .task(id: PagerID(nextBefore: state.nextBefore, generation: state.generation, isLoading: state.isLoading)) { await loadMore() }
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
            MacArtifactThumbnail(item: item, readDataURL: source.reader(appState).dataURL,
                                 dashboard: source.dashboardID(appState), profile: appState.activeProfile)
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
                .opacity(item.exists ? 1 : 0.45)
                .overlay(alignment: .topLeading) {
                    // Over the dimming, which alone reads as a dark picture, and clear of the
                    // name along the bottom.
                    if !item.exists {
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
            .opacity(item.exists ? 1 : 0.55)
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
        if !item.exists {
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
        [item.name, Self.kindLabel(item.kind), item.exists ? "" : AppLocalization.string("No longer on the host"),
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
        guard item.exists else { return .missing }
        return item.kind == .page ? .page(path: path) : .file(path: path)
    }

    private func open(_ item: ArtifactItem) {
        guard let action = Self.openAction(for: item) else { return }
        if case .link(let url) = action {
            openURL(url)
            return
        }
        guard openingID == nil else { return }
        let reader = source.reader(appState)
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
                if let dataURL = await reader.dataURL(path), !Task.isCancelled,
                   let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) {
                    page = OpenPage(name: item.name, html: html)
                    return
                }
                // Not drawable in the sheet (no data URL, over the size limit, not UTF-8): open it
                // like any other file, which also says why when it cannot.
                guard !Task.isCancelled else { return }
                await openFile(item, path: path, reader: reader)
            }
        case .file(let path):
            openingID = item.id
            openTask = Task { @MainActor in
                defer { openingID = nil }
                await openFile(item, path: path, reader: reader)
            }
        }
    }

    /// Downloads the file and shows it (quarantined, in Finder), else shows it from its data URL.
    private func openFile(_ item: ArtifactItem, path: String, reader: MacArtifactsReader) async {
        switch await reader.file(path) {
        case .downloaded(let download):
            guard !Task.isCancelled else {
                MediaPreviewPresenter.removeDirectory(download.directory)
                return
            }
            if source.present(download) { return }
        case .tooLarge:
            openFailed(item, tooLarge: true)
            return
        case .unavailable:
            break
        }
        // A cancelled download reads as unavailable; no fallback for a list that has gone.
        guard !Task.isCancelled else { return }
        guard let dataURL = await reader.dataURL(path) else {
            openFailed(item)
            return
        }
        guard !Task.isCancelled else { return }
        guard await source.presentDataURL(dataURL, item.name) else {
            openFailed(item)
            return
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
                profile: key.profile, sessionIDs: scope.sessionIDs, filter: key.filter, query: key.query,
                showMissing: key.showMissing
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
                query: request.key.query, showMissing: request.key.showMissing, before: request.before
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
    let readDataURL: @MainActor (String) async -> String?
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
        guard let dataURL = await readDataURL(path), !Task.isCancelled else { return }
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
