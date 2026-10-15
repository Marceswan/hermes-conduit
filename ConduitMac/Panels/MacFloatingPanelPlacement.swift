import CoreGraphics
import Foundation

/// One screen's geometry in AppKit's bottom-left global coordinates. The
/// controller builds it from `NSScreen`; tests build it by hand.
struct MacScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: the notch height, 0 without a notch.
    var safeAreaTop: CGFloat = 0
    /// `CGDirectDisplayID` of the display (`NSScreen.deviceDescription["NSScreenNumber"]`); nil in tests.
    var id: UInt32? = nil

    var hasNotch: Bool { safeAreaTop > 0 }
}

/// Where a floating panel goes. Pure: no AppKit windows, only rectangles.
enum MacFloatingPanelPlacement {
    /// Screen under the mouse; x centered in `visibleFrame`; `fromTop` points below its top.
    case screenCenterTop(fromTop: CGFloat)
    /// Same, with the distance as a fraction of the visible height (Quick Ask uses 0.22).
    case screenCenterTopFraction(CGFloat)
    /// A screen with a notch (else the mouse screen); x centered, top flush with the screen edge.
    case notchAnchored
    /// Docked to one edge of one screen, `offset` (0...1) of the way along it.
    /// A saved `screenID` that is gone falls back to the default, `.notchAnchored`;
    /// a nil `screenID` means the screen under the mouse.
    case edgeDocked(edge: NSRectEdge, offset: CGFloat, screenID: UInt32?)
    /// The caller computes the whole frame (the notch pill reads `NotchGeometry`).
    case custom((_ panelSize: CGSize) -> CGRect)

    func frame(panelSize: CGSize, screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect {
        switch self {
        case .screenCenterTop(let fromTop):
            return Self.topCentered(panelSize, fromTop: fromTop, in: visibleFrame)
        case .screenCenterTopFraction(let fraction):
            return Self.topCentered(panelSize, fromTop: visibleFrame.height * fraction, in: visibleFrame)
        case .notchAnchored:
            let width = min(panelSize.width, screenFrame.width)
            let height = min(panelSize.height, screenFrame.height)
            let x = min(max(screenFrame.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
            return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
        case .edgeDocked(let edge, let offset, let screenID):
            return EdgeDockGeometry.frame(
                for: MacEdgeDock(edge: edge, offset: offset, screenID: screenID),
                panelSize: panelSize, screenFrame: screenFrame)
        case .custom(let build):
            return build(panelSize)
        }
    }

    /// Index of the screen the panel belongs on, or nil with no screens.
    func targetScreenIndex(mouse: CGPoint, screens: [MacScreenGeometry]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let mouseIndex = screens.firstIndex { Self.inclusiveContains($0.frame, mouse) } ?? 0
        func notchOrMouse() -> Int {
            if screens[mouseIndex].hasNotch { return mouseIndex }
            return screens.firstIndex { $0.hasNotch } ?? mouseIndex
        }
        switch self {
        case .notchAnchored:
            return notchOrMouse()
        case .edgeDocked(_, _, let screenID):
            guard let screenID else { return mouseIndex }
            return screens.firstIndex { $0.id == screenID } ?? notchOrMouse()
        default:
            return mouseIndex
        }
    }

    /// The screen and frame for a panel of `panelSize`. A docked placement whose
    /// saved screen is gone resolves as the default (`.notchAnchored`).
    func resolve(panelSize: CGSize, mouse: CGPoint, screens: [MacScreenGeometry]) -> (screenIndex: Int, frame: CGRect)? {
        var placement = self
        if case .edgeDocked(_, _, let id?) = self, !screens.contains(where: { $0.id == id }) {
            placement = .notchAnchored
        }
        guard let index = placement.targetScreenIndex(mouse: mouse, screens: screens) else { return nil }
        let screen = screens[index]
        return (index, placement.frame(panelSize: panelSize, screenFrame: screen.frame,
                                       visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaTop))
    }

    /// The new frame when content size changes: the top edge and the
    /// horizontal center stay put, height is capped by `maxHeight` and by the
    /// room left above the bottom of `bounds`.
    static func resized(_ frame: CGRect, to size: CGSize, maxHeight: CGFloat, within bounds: CGRect) -> CGRect {
        let top = frame.maxY
        let width = min(size.width, bounds.width)
        let height = min(size.height, maxHeight, max(top - bounds.minY, 0))
        let x = min(max(frame.midX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    private static func topCentered(_ size: CGSize, fromTop: CGFloat, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let top = max(visible.minY, visible.maxY - max(fromTop, 0))
        let height = min(size.height, top - visible.minY)
        let x = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// `CGRect.contains` excludes the top and right edges; a mouse pinned to
    /// the top of a screen reports exactly `maxY`.
    private static func inclusiveContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
