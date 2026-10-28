import SwiftUI

// Search message text from the sidebar (D30). The search field filters the chats Conduit has listed by
// title and preview. This adds the chats whose messages hold the words, as an "In messages" section
// under the title matches. Hermes does the search (`GET /api/sessions/search`); upstream's
// `SessionContentSearchModel` asks it (debounced, one request at a time, remembers per connection a
// Hermes without the route). V2 Chats uses the model and stays off on Mac, so this file copies that
// behavior for the sidebar list. `SessionList` hosts `MacSidebarContentSearch` in one gated region.

/// The rules of the section. Pure, so they are tested without a view.
enum MacSidebarContentSearchRules {
    /// What the content search follows: the search field's text, and nothing in the projects view (that
    /// view lists projects and pinned chats, so there are no chats to add message matches to).
    static func query(searchText: String, showingProjects: Bool) -> String {
        showingProjects ? "" : searchText
    }

    /// What starts a new search: the words, and the connection and profile they go to.
    struct Follow: Equatable {
        let query: String
        let profile: String
        let isConnected: Bool
        let bridge: ObjectIdentifier?
    }

    /// Points the model at the field's text. A short query, the projects view or no connection clears it.
    @MainActor
    static func follow(
        _ model: SessionContentSearchModel,
        searchText: String,
        showingProjects: Bool,
        context: SessionContentSearchModel.Context?
    ) {
        model.update(query: query(searchText: searchText, showingProjects: showingProjects), context: context)
    }

    /// The message matches the list above does not show already. `listed` is the title and preview matches
    /// on screen. `known` is every chat Conduit has for the profile, for titles. `allowed`, when set (a
    /// source or status filter is on), keeps only matches among those chats. Nothing until the model's
    /// answer is for the words in the field: a redraw can come before the model drops the old hits.
    @MainActor
    static func rows(
        model: SessionContentSearchModel,
        searchText: String,
        showingProjects: Bool,
        listed: [SessionSummary],
        known: [SessionSummary],
        allowed: [SessionSummary]?
    ) -> [SessionContentSearchRow] {
        guard !model.hits.isEmpty,
              let words = SessionContentSearch.searchableQuery(query(searchText: searchText, showingProjects: showingProjects)),
              model.resultsQuery == words else { return [] }
        return SessionContentSearch.rows(hits: model.hits, listed: listed, known: known, allowed: allowed)
    }

    /// The section shows while the request runs, so the list does not look empty, and when it has rows.
    static func showsSection(rows: [SessionContentSearchRow], isSearching: Bool) -> Bool {
        !rows.isEmpty || isSearching
    }

    /// How a tap on a row opens its chat.
    enum Open: Equatable {
        /// A chat in the list: the call a sidebar row makes.
        case listed(SessionSummary)
        /// A chat older than the list: the app-link route, which reads the list again and opens it.
        case link(id: String)
    }

    static func open(_ row: SessionContentSearchRow) -> Open {
        if let session = row.session { return .listed(session) }
        return .link(id: row.openID)
    }

    /// Both routes end in `AppState.requestOpenSession`, which brings the main pane back to chat (D6).
    @MainActor
    static func perform(_ open: Open, on appState: AppState) {
        appState.dismissSidebarDrawer()
        switch open {
        case .listed(let session): appState.openListedSession(session)
        case .link(let id): appState.openAppLink(.session(id: id))
        }
    }
}

/// The text of a row. The title and the snippet come from the agent and the user: they are cleaned with
/// `MacUntrustedText` (control and format characters, such as a right-to-left override, are dropped) and
/// drawn as plain text. No Markdown, no link detection.
enum MacSidebarContentSearchText {
    static let titleLimit = 200
    static let snippetLimit = 400

    static func title(_ row: SessionContentSearchRow) -> String {
        let clean = MacUntrustedText.sanitize(row.title, maxGraphemes: titleLimit)
        return clean.isEmpty ? AppLocalization.string("Untitled conversation") : clean
    }

    /// The snippet with the same cleaning. It goes through Hermes' own match marks, so the space between
    /// two matched words stays (cleaning each run alone would trim it).
    static func snippet(_ snippet: SessionSearchSnippet) -> SessionSearchSnippet {
        let marked = snippet.runs
            .map { $0.isMatch ? SessionSearchSnippet.matchStart + $0.text + SessionSearchSnippet.matchEnd : $0.text }
            .joined()
        return SessionSearchSnippet.parse(MacUntrustedText.sanitize(marked, maxGraphemes: snippetLimit), query: "")
    }

    /// Matched words semibold in the accent color, at the size of the line around them.
    static func attributed(_ snippet: SessionSearchSnippet) -> AttributedString {
        var result = AttributedString()
        for run in snippet.runs {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.font = .caption.weight(.semibold)
                piece.foregroundColor = .conduitAccent
            }
            result += piece
        }
        return result
    }

    /// VoiceOver reads the title, then the snippet.
    static func accessibilityLabel(_ row: SessionContentSearchRow) -> String { title(row) }

    static func accessibilityValue(_ snippet: SessionSearchSnippet) -> String { snippet.plainText }
}

/// The "In messages" section of the sessions list, for the end of the list. It draws nothing until a
/// search is running or has rows.
struct MacSidebarContentSearch: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var search: SessionContentSearchModel
    @State private var feed = Feed()
    private let searchText: String
    private let showingProjects: Bool
    private let listed: [SessionSummary]
    private let allowed: [SessionSummary]?
    private let contextOverride: (@MainActor () -> SessionContentSearchModel.Context?)?

    /// The last `Follow` the model was told. A class, so that `body` can note it without a state change.
    private final class Feed {
        var last: MacSidebarContentSearchRules.Follow?
    }

    /// `model` and `context` are the seam of the tests: a model with no debounce and a fake requester. The
    /// app passes neither: the model debounces 300 ms and the context is the dashboard bridge's.
    @MainActor
    init(
        searchText: String,
        showingProjects: Bool,
        listed: [SessionSummary],
        allowed: [SessionSummary]?,
        model: SessionContentSearchModel? = nil,
        context: (@MainActor () -> SessionContentSearchModel.Context?)? = nil
    ) {
        self.searchText = searchText
        self.showingProjects = showingProjects
        self.listed = listed
        self.allowed = allowed
        self.contextOverride = context
        _search = StateObject(wrappedValue: model ?? SessionContentSearchModel())
    }

    var body: some View {
        // The search follows the field from here, in the list's own build, not from a modifier on the
        // section: a list builds the rows it shows and a modifier attaches to those rows, so a modifier
        // on the header did not start the search with the section below the fold (D30).
        let _ = scheduleFollow(follow) { contextOverride?() ?? appState.sessionContentSearchContext }
        let known = search.hits.isEmpty ? [] : appState.activeProfileSessions + appState.activeProfileCronSessions
        let rows = MacSidebarContentSearchRules.rows(
            model: search, searchText: searchText, showingProjects: showingProjects,
            listed: listed, known: known, allowed: allowed
        )
        if MacSidebarContentSearchRules.showsSection(rows: rows, isSearching: search.isSearching) {
            Section {
                ForEach(rows) { row in contentRow(row) }
            } header: {
                header
            }
        }
    }

    private var follow: MacSidebarContentSearchRules.Follow {
        MacSidebarContentSearchRules.Follow(
            query: MacSidebarContentSearchRules.query(searchText: searchText, showingProjects: showingProjects),
            profile: appState.activeProfile,
            isConnected: appState.isConnected,
            bridge: appState.dashboardTicketBridge.map { ObjectIdentifier($0) }
        )
    }

    /// Tells the model about a changed `follow`, once. The model publishes, and a view update must not
    /// publish, so the model is told after the update, on the main actor. Nothing observed is written here.
    /// `body` runs on every change of the app state, so the context is built only for a changed `follow`.
    private func scheduleFollow(
        _ follow: MacSidebarContentSearchRules.Follow,
        context makeContext: () -> SessionContentSearchModel.Context?
    ) {
        guard feed.last != follow else { return }
        feed.last = follow
        let model = search
        let text = searchText
        let projects = showingProjects
        let context = makeContext()
        Task { @MainActor in
            MacSidebarContentSearchRules.follow(model, searchText: text, showingProjects: projects, context: context)
        }
    }

    /// "In messages", with a spinner while Hermes is still searching.
    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: AppLocalization.string("In messages"))
                .accessibilityAddTraits(.isHeader)
            if search.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(Text(verbatim: AppLocalization.string("Searching messages")))
            }
        }
    }

    /// A chat Hermes found by its messages: its title, then the matching line with the match picked out.
    private func contentRow(_ row: SessionContentSearchRow) -> some View {
        let snippet = MacSidebarContentSearchText.snippet(row.hit.snippet)
        return Button {
            Haptics.light()
            MacSidebarContentSearchRules.perform(MacSidebarContentSearchRules.open(row), on: appState)
        } label: {
            MacContentMatchCard(
                title: MacSidebarContentSearchText.title(row),
                snippet: snippet,
                source: row.session.map { appState.sessionCategory(for: $0) } ?? .chat,
                isUnread: row.session.map { appState.isSessionUnread($0) } ?? false,
                isSelected: row.openID == appState.activeSessionId
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: MacSidebarContentSearchText.accessibilityLabel(row)))
            .accessibilityValue(Text(verbatim: MacSidebarContentSearchText.accessibilityValue(snippet)))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: MacSidebarMetrics.sessionRowInset, leading: 0, bottom: MacSidebarMetrics.sessionRowInset, trailing: 0))
    }
}

/// The card of a message match: the look of `SessionRow` (icon, card, density) with the matching line under
/// the title.
private struct MacContentMatchCard: View {
    let title: String
    let snippet: SessionSearchSnippet
    let source: SessionSource
    let isUnread: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: source.iconName)
                .font(.caption.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(source.color)
                .frame(width: MacSidebarMetrics.sessionIconSize, height: MacSidebarMetrics.sessionIconSize)
                .background(source.color.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(isUnread ? .semibold : .medium))
                    .lineLimit(1)
                if !snippet.runs.isEmpty {
                    Text(MacSidebarContentSearchText.attributed(snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
            if isUnread {
                Circle()
                    .fill(SessionStatusFilter.unread.color)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, MacSidebarMetrics.sessionCardPaddingH)
        .padding(.vertical, MacSidebarMetrics.sessionCardPaddingV)
        .background(
            isSelected ? Color.conduitAccent.opacity(0.15) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: MacSidebarMetrics.sessionCardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MacSidebarMetrics.sessionCardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.conduitAccent.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
