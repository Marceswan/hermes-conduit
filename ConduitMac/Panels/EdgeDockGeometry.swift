import Foundation

/// Where a panel is docked: one edge of one screen, a fraction along it.
struct MacEdgeDock: Equatable {
    /// AppKit coordinates: `.maxY` top, `.minY` bottom, `.minX` left, `.maxX` right.
    var edge: NSRectEdge
    /// 0...1 along the edge: left to right on top and bottom, top to bottom on left and right.
    var offset: CGFloat
    /// `CGDirectDisplayID` of the screen, or nil for "the screen under the mouse".
    var screenID: UInt32?
}

/// Pure edge-dock math. No windows, no screens: rectangles in, rectangles out.
enum EdgeDockGeometry {
    static func clampedOffset(_ offset: CGFloat) -> CGFloat {
        guard !offset.isNaN else { return 0.5 }
        return min(max(offset, 0), 1)
    }

    /// Flush with `dock.edge` of `screenFrame`, `offset` of the way along it,
    /// and always fully on screen (a panel longer than the screen shrinks to it).
    static func frame(for dock: MacEdgeDock, panelSize: CGSize, screenFrame f: CGRect) -> CGRect {
        let width = min(panelSize.width, f.width)
        let height = min(panelSize.height, f.height)
        let t = clampedOffset(dock.offset)
        let x = f.minX + (f.width - width) * t
        let y = f.maxY - height - (f.height - height) * t
        switch dock.edge {
        case .maxY: return CGRect(x: x, y: f.maxY - height, width: width, height: height)
        case .minY: return CGRect(x: x, y: f.minY, width: width, height: height)
        case .minX: return CGRect(x: f.minX, y: y, width: width, height: height)
        case .maxX: return CGRect(x: f.maxX - width, y: y, width: width, height: height)
        @unknown default: return CGRect(x: x, y: f.maxY - height, width: width, height: height)
        }
    }

    /// The screen edge closest to `pointer`. Ties prefer top, then bottom, then left, then right.
    static func nearestEdge(to pointer: CGPoint, in f: CGRect) -> NSRectEdge {
        let candidates: [(NSRectEdge, CGFloat)] = [
            (.maxY, f.maxY - pointer.y), (.minY, pointer.y - f.minY),
            (.minX, pointer.x - f.minX), (.maxX, f.maxX - pointer.x),
        ]
        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.1 < best.1 { best = candidate }
        return best.0
    }

    /// Where `panelFrame` sits along `edge`, as a clamped fraction. A panel as
    /// long as the edge has no room to move and reads as centered.
    static func offset(of panelFrame: CGRect, on edge: NSRectEdge, in f: CGRect) -> CGFloat {
        switch edge {
        case .maxY, .minY:
            let room = f.width - panelFrame.width
            return room > 0 ? clampedOffset((panelFrame.minX - f.minX) / room) : 0.5
        default:
            let room = f.height - panelFrame.height
            return room > 0 ? clampedOffset((f.maxY - panelFrame.maxY) / room) : 0.5
        }
    }

    /// The screen containing `point` (edges inclusive), else the nearest one.
    static func screenIndex(containing point: CGPoint, in screens: [MacScreenGeometry]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let hit = screens.firstIndex(where: { contains($0.frame, point) }) { return hit }
        return screens.indices.min { distance(from: point, to: screens[$0].frame) < distance(from: point, to: screens[$1].frame) }
    }

    /// The screen a dock names, or nil (no id, or that screen is gone).
    static func screenIndex(for dock: MacEdgeDock, screens: [MacScreenGeometry]) -> Int? {
        guard let id = dock.screenID else { return nil }
        return screens.firstIndex { $0.id == id }
    }

    /// Mouse-up after a drag: the dock for the screen under the pointer, its
    /// nearest edge, and the panel's offset along that edge.
    static func snap(pointer: CGPoint, panelFrame: CGRect, screens: [MacScreenGeometry]) -> MacEdgeDock? {
        guard let index = screenIndex(containing: pointer, in: screens) else { return nil }
        let screen = screens[index]
        let edge = nearestEdge(to: pointer, in: screen.frame)
        return MacEdgeDock(edge: edge, offset: offset(of: panelFrame, on: edge, in: screen.frame), screenID: screen.id)
    }

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    private static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
