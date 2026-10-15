import Foundation

/// Which dashboard and profile an index belongs to (D19).
struct MacSpotlightScope: Equatable {
    var dashboardID: UUID?
    var profile: String

    var dashboardKey: String { dashboardID?.uuidString ?? "none" }
    var encodedProfile: String { MacSpotlightItemID.encode(profile) }
    var domainIdentifier: String { "conduit|\(dashboardKey)|\(encodedProfile)" }
    /// UserDefaults key for this scope's snapshot.
    var snapshotKey: String { "\(MacSpotlightScope.snapshotKeyPrefix)\(dashboardKey).\(profile)" }

    static let snapshotKeyPrefix = "conduit.mac.spotlight."
}

/// What Spotlight shows for one chat. A plain value so tests need no index.
struct MacSpotlightItem: Equatable {
    var uniqueIdentifier: String
    var domainIdentifier: String
    var title: String
    var contentDescription: String
    var modified: Date?
}

/// `conduit|<dashboardKey>|<percent-encoded profile>|<session id>`. The session
/// id is last and unencoded so it may hold any character; parsing splits at
/// most three times.
struct MacSpotlightItemID: Equatable {
    var dashboardKey: String
    var profile: String
    var sessionID: String

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func make(scope: MacSpotlightScope, sessionID: String) -> String {
        "\(scope.domainIdentifier)|\(sessionID)"
    }

    static func parse(_ raw: String) -> MacSpotlightItemID? {
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "conduit",
              !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty,
              let profile = parts[2].removingPercentEncoding, !profile.isEmpty else { return nil }
        return MacSpotlightItemID(dashboardKey: parts[1], profile: profile, sessionID: parts[3])
    }
}

enum MacSpotlightItemFactory {
    /// Cron runs, voice job rows and archived rows are never indexed. Bot chats
    /// are already absent from `activeProfileSessions`.
    static func isIndexable(_ s: SessionSummary) -> Bool {
        guard !s.isArchived else { return false }
        return s.source != .cron && s.source != .voiceJob
    }

    /// Title and metadata only. Message text is never read (D19).
    static func item(for s: SessionSummary, scope: MacSpotlightScope) -> MacSpotlightItem {
        let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var details: [String] = []
        if !s.model.isEmpty { details.append(s.model) }
        if let messageCount = s.messageCount {
            details.append(AppLocalization.string("\(messageCount) messages"))
        }
        return MacSpotlightItem(
            uniqueIdentifier: MacSpotlightItemID.make(scope: scope, sessionID: s.id),
            domainIdentifier: scope.domainIdentifier,
            title: title.isEmpty ? AppLocalization.string("New conversation") : title,
            contentDescription: details.joined(separator: " \u{00B7} "),
            modified: s.lastActivityAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
