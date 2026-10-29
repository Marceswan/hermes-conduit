import AppKit

struct NotchScreenMetrics: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect
    var auxiliaryTopRight: CGRect
    /// `CGDirectDisplayID`, the key for the per-display dock; nil in tests.
    var id: UInt32? = nil

    /// The screen of the key window, else the primary (`NSScreen.main`).
    @MainActor static func main() -> NotchScreenMetrics? {
        NSScreen.main.map(metrics(of:))
    }

    /// A connected display by `CGDirectDisplayID`.
    @MainActor static func display(id: UInt32) -> NotchScreenMetrics? {
        NSScreen.screens.first { screenID($0) == id }.map(metrics(of:))
    }

    private static func screenID(_ s: NSScreen) -> UInt32? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor private static func metrics(of s: NSScreen) -> NotchScreenMetrics {
        NotchScreenMetrics(
            frame: s.frame, visibleFrame: s.visibleFrame,
            safeAreaTop: s.safeAreaInsets.top,
            auxiliaryTopLeft: s.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRight: s.auxiliaryTopRightArea ?? .zero,
            id: screenID(s))
    }
}

enum NotchPlacement: Equatable {
    case notch(notchRect: CGRect)
    case pill

    var notchWidth: CGFloat { if case .notch(let r) = self { r.width } else { 0 } }
    var notchHeight: CGFloat { if case .notch(let r) = self { r.height } else { 0 } }
}

enum NotchMetrics {
    static let leftWing: CGFloat = 36
    static let rightWing: CGFloat = 124
    static let pillHeight: CGFloat = 28
    static let pillMinWidth: CGFloat = 160
    static let pillMaxWidth: CGFloat = 260
    static let pillGap: CGFloat = 4
    static let expandedWidth: CGFloat = 380
}

enum NotchGeometry {
    /// `safeAreaInsets.top` is the notch height; the auxiliary areas are the
    /// unobscured menu bar rects either side of it (NSScreen.h, macOS 12+).
    static func placement(for m: NotchScreenMetrics) -> NotchPlacement {
        guard m.safeAreaTop > 0, !m.auxiliaryTopLeft.isEmpty, !m.auxiliaryTopRight.isEmpty else { return .pill }
        let minX = m.auxiliaryTopLeft.maxX, maxX = m.auxiliaryTopRight.minX
        guard maxX > minX else { return .pill }
        return .notch(notchRect: CGRect(x: minX, y: m.frame.maxY - m.safeAreaTop, width: maxX - minX, height: m.safeAreaTop))
    }

    static func compactFrame(_ p: NotchPlacement, in m: NotchScreenMetrics, contentWidth: CGFloat) -> CGRect {
        switch p {
        case .notch(let n):
            let left = min(NotchMetrics.leftWing, m.auxiliaryTopLeft.width)
            let right = min(NotchMetrics.rightWing, m.auxiliaryTopRight.width)
            return CGRect(x: n.minX - left, y: n.minY, width: n.width + left + right, height: n.height)
        case .pill:
            let w = min(max(contentWidth, NotchMetrics.pillMinWidth), NotchMetrics.pillMaxWidth)
            return CGRect(x: m.visibleFrame.midX - w / 2,
                          y: m.visibleFrame.maxY - NotchMetrics.pillGap - NotchMetrics.pillHeight,
                          width: w, height: NotchMetrics.pillHeight)
        }
    }

    static func expandedFrame(_ p: NotchPlacement, in m: NotchScreenMetrics, height: CGFloat) -> CGRect {
        let w = NotchMetrics.expandedWidth
        let h = min(height, m.visibleFrame.height - 8)
        switch p {
        case .notch(let n):
            let x = min(max(n.midX - w / 2, m.frame.minX), m.frame.maxX - w)
            return CGRect(x: x, y: m.frame.maxY - h, width: w, height: h)
        case .pill:
            let x = min(max(m.visibleFrame.midX - w / 2, m.frame.minX), m.frame.maxX - w)
            return CGRect(x: x, y: m.visibleFrame.maxY - NotchMetrics.pillGap - h, width: w, height: h)
        }
    }
}
