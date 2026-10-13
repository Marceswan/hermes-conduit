import AppKit
import SwiftUI

/// Borderless tooltip bubble shown after the pointer rests on a control.
final class TooltipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private static let padding = NSSize(width: 6, height: 3)
    private static let maxTextWidth: CGFloat = 320

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        background.layer?.masksToBounds = true
        label.font = NSFont.toolTipsFont(ofSize: 0)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        background.addSubview(label)
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ text: String, near pointer: NSPoint) {
        label.stringValue = text
        let textSize = label.sizeThatFits(NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(textSize.width) + Self.padding.width * 2,
                          height: ceil(textSize.height) + Self.padding.height * 2)
        label.frame = NSRect(x: Self.padding.width, y: Self.padding.height,
                             width: ceil(textSize.width), height: ceil(textSize.height))
        var origin = NSPoint(x: pointer.x + 12, y: pointer.y - 18 - size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

/// Outline drawn over the control under the pointer: the control's own
/// rounded shape, a faint accent wash, a thin accent stroke and a soft glow.
/// The colour is the app accent (`Color.conduitAccent`), never system blue.
final class HighlightWindow: NSWindow {
    /// Room around the control for the glow; the window is this much larger.
    static let glowInset: CGFloat = 8

    private final class OutlineView: NSView {
        var path: NSBezierPath?

        override func draw(_ dirtyRect: NSRect) {
            guard let path else { return }
            let accent = HighlightWindow.accentColor
            NSGraphicsContext.saveGraphicsState()
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            let glow = NSShadow()
            glow.shadowColor = accent.withAlphaComponent(0.45)
            glow.shadowBlurRadius = 6
            glow.shadowOffset = .zero
            glow.set()
            accent.withAlphaComponent(0.70).setStroke()
            let stroke = path.copy() as! NSBezierPath
            stroke.lineWidth = 1
            stroke.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The app accent as an AppKit colour. Dynamic: resolves against the
    /// drawing appearance, like the SwiftUI colour it comes from.
    static var accentColor: NSColor { NSColor(Color.conduitAccent) }

    private let outline = OutlineView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = outline
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var closeObserver: NSObjectProtocol?
    private var shownShape: HoverOutlineShape?

    func show(shape: HoverOutlineShape, over newParent: NSWindow) {
        let frame = shape.frame.insetBy(dx: -Self.glowInset, dy: -Self.glowInset)
        if parent === newParent, shownShape == shape, self.frame == frame { return }
        if parent !== newParent {
            parent?.removeChildWindow(self)
            newParent.addChildWindow(self, ordered: .above)
            closeObserver.map(NotificationCenter.default.removeObserver)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newParent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        appearance = newParent.effectiveAppearance
        if self.frame != frame { setFrame(frame, display: false) }
        outline.path = shape.path(relativeTo: frame.origin)
        outline.needsDisplay = true
        shownShape = shape
    }

    func hide() {
        guard parent != nil || isVisible else { return }
        closeObserver.map(NotificationCenter.default.removeObserver)
        closeObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        shownShape = nil
    }
}
