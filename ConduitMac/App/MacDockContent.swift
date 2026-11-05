import Foundation

// Dock badge and Dock menu content (D31), pure: no AppKit, AppState or feed types, so the tests need no windows.
// It reads Home's snapshot (`MacHomeSnapshot`, D24). The Dock count is the Home "waiting on you" tile, and the
// menu lists Home's Needs you and Recent rows, with Home's offline rule, one row per session, order and text
// cleaning. A change to one of these rules changes the Dock with it; `MacDockTests` pins that.

/// What the Dock reads: the feed's live rows, the chats of the active profile, and the feed's availability.
struct MacDockSnapshot: Equatable {
    var feed: MacHomeFeedAvailability
    var live: [MacHomeLiveItem]
    /// Empty for the badge, which has no use for chats.
    var sessions: [MacHomeSession]
}

struct MacDockItem: Equatable {
    enum Action: Equatable {
        case newChat
        case quickAsk
        /// The id that a Home or notch row opens (`requestOpenSession`).
        case openSession(String)
        /// A row that has no session to open.
        case openConduit
    }

    var title: String
    var action: Action
}

enum MacDockEntry: Equatable {
    case item(MacDockItem)
    case separator
}

enum MacDockContent {
    static let needsYouLimit = 5
    static let recentLimit = 5
    /// Graphemes in a chat title: a Dock menu is as wide as its longest title.
    static let titleLimit = 50

    /// Approvals plus questions, counted per item; zero while the feed is offline. The Home tile's number.
    static func waitingCount(_ snapshot: MacDockSnapshot) -> Int {
        home(snapshot).tiles.needsYou
    }

    /// New Chat, Quick Ask, then the chats that need the user, then the recent chats. An empty group has no
    /// separator.
    static func entries(_ snapshot: MacDockSnapshot) -> [MacDockEntry] {
        let home = home(snapshot)
        var entries: [MacDockEntry] = [
            .item(MacDockItem(title: AppLocalization.string("New Chat"), action: .newChat)),
            .item(MacDockItem(title: AppLocalization.string("Quick Ask"), action: .quickAsk)),
        ]
        let needsYou = home.needsYou.prefix(needsYouLimit).map { row in
            MacDockEntry.item(MacDockItem(title: title(row.title), action: row.openID.map { .openSession($0) } ?? .openConduit))
        }
        let recent = home.recent.prefix(recentLimit).map { row in
            MacDockEntry.item(MacDockItem(title: title(row.title), action: .openSession(row.id)))
        }
        for group in [needsYou, recent] where !group.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: group)
        }
        return entries
    }

    private static func home(_ snapshot: MacDockSnapshot) -> MacHomeSnapshot {
        MacHomeSnapshot.make(MacHomeInput(
            // Day buckets and cron read the time; the Dock reads neither.
            now: Date(timeIntervalSince1970: 0),
            scope: "",
            connection: MacHomeConnection(state: .connected, dashboardLabel: nil, profileName: ""),
            sessions: snapshot.sessions,
            live: snapshot.live,
            feed: snapshot.feed,
            cron: nil,
            kanban: .notLoaded,
            runtime: MacHomeRuntime(),
            subAgents: 0,
            canStartChat: false
        ))
    }

    /// The text is gateway- and agent-controlled: it is made safe again at the Dock's own length.
    private static func title(_ text: String) -> String {
        let clean = MacUntrustedText.sanitize(text, maxGraphemes: titleLimit)
        return clean.isEmpty ? AppLocalization.string("Untitled chat") : clean
    }
}
