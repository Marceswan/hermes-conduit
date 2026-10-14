import AppKit

/// The glass platter the system draws behind a window-toolbar item (macOS 26
/// and later): the shape the user sees, as opposed to the toolbar item's
/// accessibility frame.
///
/// The accessibility frame of a toolbar control is its `NSToolbarItemViewer`
/// (an AppKit view): the full 52 pt toolbar height, plus 4 pt of item spacing
/// on one side, so a 36 pt round button reports 40 x 52. A title pill's inner
/// SwiftUI node reports only its text. Neither matches the platter, so the
/// hover outline is taken from the platter itself (D7).
struct ToolbarPlatter: Equatable {
    /// Screen coordinates (AppKit, bottom-left origin).
    var frame: CGRect
    /// The glass view's `cornerRadius` (18 on macOS 27: a circle at 36 x 36,
    /// a capsule on a wider platter).
    var cornerRadius: CGFloat
}

enum ToolbarPlatterGeometry {
    /// A toolbar platter is 36 pt tall; anything taller is not one.
    static let maxPlatterHeight: CGFloat = 44
    /// How much wider than the element a platter may be. A title pill's text
    /// node sits inside 12 pt of padding on each side; two items merged onto
    /// one platter would exceed this and keep their own frames.
    static let maxHorizontalOutset: CGFloat = 32

    /// The platter drawn behind the element whose accessibility frame is
    /// `elementFrame`: the smallest platter that contains the frame's centre,
    /// is toolbar-sized, and is not much wider than the element. Nil when the
    /// element does not sit on a platter (a content-area button, an older
    /// macOS), so its own frame is used.
    static func platter(for elementFrame: CGRect, among platters: [ToolbarPlatter]) -> ToolbarPlatter? {
        guard !elementFrame.isEmpty else { return nil }
        let center = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
        return platters
            .filter {
                $0.frame.contains(center)
                    && $0.frame.height <= maxPlatterHeight
                    && $0.frame.width <= elementFrame.width + maxHorizontalOutset
            }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The glass platters of `window`'s toolbar, in screen coordinates. They
    /// are the `NSGlassEffectView`s under the titlebar view (reached through
    /// the public close button's superview); content below the titlebar is
    /// never searched. Empty before macOS 26 and when the window has no
    /// titlebar (full screen moves the toolbar to another window).
    @MainActor
    static func platters(in window: NSWindow, near elementFrame: CGRect) -> [ToolbarPlatter] {
        guard #available(macOS 26.0, *),
              let titlebar = window.standardWindowButton(.closeButton)?.superview else { return [] }
        let strip = window.convertToScreen(titlebar.convert(titlebar.bounds, to: nil))
        guard strip.intersects(elementFrame) else { return [] }
        var found: [ToolbarPlatter] = []
        func walk(_ view: NSView, depth: Int) {
            if view.isHidden || view.alphaValue < 0.01 { return }
            if let glass = view as? NSGlassEffectView {
                let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                found.append(ToolbarPlatter(frame: frame, cornerRadius: glass.cornerRadius))
                return
            }
            guard depth < 7 else { return }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(titlebar, depth: 0)
        return found
    }
}
