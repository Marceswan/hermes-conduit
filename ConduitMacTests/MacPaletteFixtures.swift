import Foundation
@testable import ConduitMac

extension MacPaletteItem {
    /// A command-kind item with a stable id, for matcher tests.
    static func fixture(
        _ title: String,
        kind: MacPaletteKind = .command,
        id: String? = nil,
        keywords: [String] = [],
        enabled: Bool = true,
        unread: Bool = false,
        active: Bool = false,
        lastActivityAt: TimeInterval? = nil
    ) -> MacPaletteItem {
        MacPaletteItem(
            id: id ?? "\(kind.rawValue):\(title)", kind: kind, title: title, keywords: keywords,
            isEnabled: enabled, isUnread: unread, isActiveSession: active,
            lastActivityAt: lastActivityAt, action: .newChat
        )
    }
}

extension SessionSummary {
    /// A palette-test session: `macTestSummary` plus the fields the palette reads.
    static func paletteFixture(
        id: String, title: String, model: String = "", archived: Bool = false,
        pinned: Bool? = nil, lastActivityAt: TimeInterval? = nil
    ) -> SessionSummary {
        var s = SessionSummary.macTestSummary(id: id, alternateIds: [], title: title)
        s.model = model
        s.isArchived = archived
        s.isPinned = pinned
        s.lastActivityAt = lastActivityAt
        return s
    }
}
