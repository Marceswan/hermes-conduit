import AppKit

/// The shape of the hover outline for one control.
///
/// The accessibility layer reports a frame for every element, which alone
/// gives a rectangle. SwiftUI nodes also answer `accessibilityPath` with the
/// control's own shape in screen coordinates: the glass or background shape
/// it draws, or the shape it declares with `.contentShape(.accessibility, _)`
/// or `.contentShape(_)`. That path is used when it matches the frame. A
/// control that wants a particular outline therefore declares its corner
/// radius with a standard SwiftUI modifier, and the engine needs no registry.
/// Anything without a usable path (AppKit controls, odd nodes) gets a rounded
/// rectangle with radius `min(height / 2, 18)`: a capsule for a typical
/// button, never the near-square corners of a plain rectangle.
///
/// A window-toolbar item is the exception: its accessibility frame is the
/// toolbar item's whole 52 pt slot, not the 36 pt glass platter drawn in it,
/// so such an element passes its `ToolbarPlatter` and the outline is the
/// platter's frame and corner radius (a circle, a capsule).
struct HoverOutlineShape: Equatable {
    /// Screen coordinates (AppKit, bottom-left origin).
    var frame: CGRect
    /// The control's own shape in screen coordinates, when usable.
    var accessibilityPath: NSBezierPath?
    /// Explicit corner radius (a toolbar platter's); nil uses the heuristic.
    var cornerRadius: CGFloat?

    /// Upper bound for the fallback radius; also what a capsule button gets.
    static let maxFallbackRadius: CGFloat = 18
    /// How far the reported path's bounds may differ from the frame, per edge.
    static let pathTolerance: CGFloat = 1.5

    static func fallbackRadius(for frame: CGRect) -> CGFloat {
        max(0, min(min(frame.width, frame.height) / 2, maxFallbackRadius))
    }

    /// Keeps `axPath` only when it is a non-empty path whose bounds match
    /// `frame`; otherwise the outline falls back to the heuristic radius.
    static func make(frame: CGRect, axPath: NSBezierPath?, platter: ToolbarPlatter? = nil) -> HoverOutlineShape {
        if let platter {
            return HoverOutlineShape(frame: platter.frame, accessibilityPath: nil,
                                     cornerRadius: clampedRadius(platter.cornerRadius, for: platter.frame))
        }
        guard let axPath, axPath.elementCount > 0, pathMatches(axPath.bounds, frame: frame) else {
            return HoverOutlineShape(frame: frame, accessibilityPath: nil)
        }
        return HoverOutlineShape(frame: frame, accessibilityPath: axPath)
    }

    /// `radius` limited to half the shorter side, so a radius larger than the
    /// frame still draws a circle or capsule.
    static func clampedRadius(_ radius: CGFloat, for frame: CGRect) -> CGFloat {
        max(0, min(radius, min(frame.width, frame.height) / 2))
    }

    static func pathMatches(_ bounds: CGRect, frame: CGRect) -> Bool {
        abs(bounds.minX - frame.minX) <= pathTolerance && abs(bounds.maxX - frame.maxX) <= pathTolerance
            && abs(bounds.minY - frame.minY) <= pathTolerance && abs(bounds.maxY - frame.maxY) <= pathTolerance
    }

    /// The outline path in the coordinates of a window whose origin is
    /// `windowOrigin` (screen coordinates).
    func path(relativeTo windowOrigin: CGPoint) -> NSBezierPath {
        let local = CGRect(x: frame.minX - windowOrigin.x, y: frame.minY - windowOrigin.y,
                           width: frame.width, height: frame.height)
        guard let accessibilityPath else {
            let radius = cornerRadius ?? Self.fallbackRadius(for: frame)
            return NSBezierPath(roundedRect: local, xRadius: radius, yRadius: radius)
        }
        let moved = accessibilityPath.copy() as! NSBezierPath
        moved.transform(using: AffineTransform(translationByX: -windowOrigin.x, byY: -windowOrigin.y))
        return moved
    }
}
