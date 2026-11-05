import AppKit

/// Per-display memory of where the user docked the surface, keyed by the
/// display's `CGDirectDisplayID` (`MacScreenGeometry.id`). Anything unreadable
/// reads as "not docked", so a bad record can never put the surface off-screen.
struct NotchDockStore {
    static let keyPrefix = "conduit.mac.notchStatus.dock."
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func key(_ screenID: UInt32) -> String { "\(keyPrefix)\(screenID)" }

    private static let edges: [Int: NSRectEdge] = [
        Int(NSRectEdge.maxY.rawValue): .maxY, Int(NSRectEdge.minY.rawValue): .minY,
        Int(NSRectEdge.minX.rawValue): .minX, Int(NSRectEdge.maxX.rawValue): .maxX,
    ]

    func dock(forScreen id: UInt32) -> MacEdgeDock? {
        guard let record = defaults.dictionary(forKey: Self.key(id)),
              let raw = record["edge"] as? Int, let edge = Self.edges[raw],
              let offset = record["offset"] as? Double, offset.isFinite else { return nil }
        return MacEdgeDock(edge: edge, offset: EdgeDockGeometry.clampedOffset(CGFloat(offset)), screenID: id)
    }

    /// A dock with no display id cannot be restored, so it is not stored.
    func save(_ dock: MacEdgeDock) {
        guard let id = dock.screenID else { return }
        defaults.set(["edge": Int(dock.edge.rawValue), "offset": Double(EdgeDockGeometry.clampedOffset(dock.offset))],
                     forKey: Self.key(id))
    }

    func clear(screenID id: UInt32) { defaults.removeObject(forKey: Self.key(id)) }
}

enum NotchPlacementChoice: Equatable {
    /// Notch wings on a notch display, else the top-center pill.
    case standard
    case docked(MacEdgeDock)
}

enum NotchPlacementResolver {
    /// The saved dock when its display is connected and the record is valid, else `.standard`.
    static func choose(screenID: UInt32?, connectedScreenIDs: Set<UInt32>, store: NotchDockStore) -> NotchPlacementChoice {
        guard let screenID, connectedScreenIDs.contains(screenID), let dock = store.dock(forScreen: screenID) else { return .standard }
        return .docked(dock)
    }
}
