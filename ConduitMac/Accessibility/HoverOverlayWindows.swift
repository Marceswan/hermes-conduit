import AppKit

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

/// Rounded accent wash drawn over the control under the pointer.
final class HighlightWindow: NSWindow {
    private final class FillView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = FillView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var closeObserver: NSObjectProtocol?

    func show(around elementFrame: CGRect, over newParent: NSWindow) {
        let frame = elementFrame.insetBy(dx: -2, dy: -2)
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
        if self.frame != frame { setFrame(frame, display: true) }
    }

    func hide() {
        guard parent != nil || isVisible else { return }
        closeObserver.map(NotificationCenter.default.removeObserver)
        closeObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
