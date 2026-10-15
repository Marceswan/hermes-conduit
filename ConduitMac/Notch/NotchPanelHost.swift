import AppKit
import SwiftUI

@MainActor
protocol NotchPanelHosting: AnyObject {
    var isVisible: Bool { get }
    var onPointerChange: ((Bool) -> Void)? { get set }
    var onDockChanged: ((MacEdgeDock) -> Void)? { get set }
    var onDragStateChange: ((Bool) -> Void)? { get set }
    var inwardSide: NotchInwardSide { get set }
    func show()
    func hide()
    func setFrame(_ frame: CGRect, animated: Bool)
    func setDock(_ dock: MacEdgeDock, size: CGSize)
}

enum NotchHitShape {
    /// AppKit coordinates (y up). Only the two corners on `side` are rounded.
    static func contains(_ p: CGPoint, in b: CGRect, inward side: NotchInwardSide, radius r: CGFloat) -> Bool {
        guard b.contains(p) else { return false }
        let centres: [CGPoint]
        switch side {
        case .bottom: centres = [CGPoint(x: b.minX + r, y: b.minY + r), CGPoint(x: b.maxX - r, y: b.minY + r)]
        case .top: centres = [CGPoint(x: b.minX + r, y: b.maxY - r), CGPoint(x: b.maxX - r, y: b.maxY - r)]
        case .leading: centres = [CGPoint(x: b.minX + r, y: b.minY + r), CGPoint(x: b.minX + r, y: b.maxY - r)]
        case .trailing: centres = [CGPoint(x: b.maxX - r, y: b.minY + r), CGPoint(x: b.maxX - r, y: b.maxY - r)]
        }
        for c in centres {
            let inX = c.x < b.midX ? p.x < c.x : p.x > c.x
            let inY = c.y < b.midY ? p.y < c.y : p.y > c.y
            if inX && inY && hypot(p.x - c.x, p.y - c.y) > r { return false }
        }
        return true
    }
}

final class NotchHitContainer: NSView {
    var inwardSide: NotchInwardSide = .bottom
    var radius: CGFloat = 14

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return NotchHitShape.contains(local, in: bounds, inward: inwardSide, radius: radius) ? super.hitTest(point) : nil
    }
}

@MainActor
final class NotchPanelHost: NotchPanelHosting {
    var onPointerChange: ((Bool) -> Void)?
    var onDockChanged: ((MacEdgeDock) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var inwardSide: NotchInwardSide = .bottom { didSet { hitContainer?.inwardSide = inwardSide } }

    private enum Applied: Equatable { case frame(CGRect), dock(MacEdgeDock, CGSize) }
    private var frame = CGRect(x: 0, y: 0, width: NotchMetrics.expandedWidth, height: NotchMetrics.pillHeight)
    private var applied: Applied?
    private var dragBegan = false
    private let controller: MacFloatingPanelController
    private var hitContainer: NotchHitContainer?

    private final class WeakBox { weak var host: NotchPanelHost? }

    init<Content: View>(content: Content, environment: MacFloatingPanelEnvironment = .live) {
        let box = WeakBox()
        var config = MacFloatingPanelConfig(
            size: frame.size, placement: .custom { _ in box.host?.frame ?? .zero },
            canBecomeKey: false, dismissOnResignKey: false)
        config.dismissOnEscape = false          // the controller handles Esc itself
        config.level = .statusBar
        config.joinsAllSpaces = true
        config.allowsMenuBarOverlap = true
        config.hasShadow = false
        config.onMouseEntered = { box.host?.handlePointer(true) }
        config.onMouseExited = { box.host?.handlePointer(false) }
        config.isDraggable = true               // the whole surface is the handle; the base keeps sub-threshold presses as clicks
        config.onPlacementChanged = { placement in
            if case .edgeDocked(let edge, let offset, let id) = placement {
                box.host?.onDockChanged?(MacEdgeDock(edge: edge, offset: offset, screenID: id))
            }
        }
        controller = MacFloatingPanelController(config: config, environment: environment) { content }
        box.host = self
        chainDragCallbacks()
        installHitContainer()
    }

    var isVisible: Bool { controller.isVisible }
    func show() { controller.show() }
    func hide() { controller.hide() }

    func setFrame(_ new: CGRect, animated: Bool) {
        frame = new
        guard applied != .frame(new) else { return }
        applied = .frame(new)
        controller.setPlacement(.custom { [weak self] _ in self?.frame ?? .zero })
    }

    func setDock(_ dock: MacEdgeDock, size: CGSize) {
        guard applied != .dock(dock, size) else { return }
        applied = .dock(dock, size)
        controller.setPlacement(.edgeDocked(edge: dock.edge, offset: dock.offset, screenID: dock.screenID))
        controller.updateContentSize(size)
    }

    private func handlePointer(_ inside: Bool) { onPointerChange?(inside) }

    /// The base wires `onDragMoved` / `onDragEnded` for its own bookkeeping;
    /// keep those and add the drag-state report on top.
    private func chainDragCallbacks() {
        let panel = controller.panel
        let moved = panel.onDragMoved
        panel.onDragMoved = { [weak self] f in
            moved?(f)
            guard let self, !dragBegan else { return }
            dragBegan = true
            onDragStateChange?(true)
        }
        let ended = panel.onDragEnded
        panel.onDragEnded = { [weak self] pointer, f in
            ended?(pointer, f)                  // the base snaps and calls onPlacementChanged first
            guard let self else { return }
            dragBegan = false
            onDragStateChange?(false)
        }
    }

    /// Clicks pass through the clear rounded corners: the hit area is the visible shape.
    private func installHitContainer() {
        guard let hosting = controller.panel.contentView else { return }
        let container = NotchHitContainer(frame: hosting.frame)
        container.autoresizingMask = [.width, .height]
        controller.panel.contentView = container
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.inwardSide = inwardSide
        hitContainer = container
    }

    // Test seams.
    var panelForTesting: MacFloatingPanel { controller.panel }
    var targetFrameForTesting: CGRect { controller.targetFrame }
    func simulatePointerForTesting(inside: Bool) { handlePointer(inside) }
    /// The container when `p` (in its own coordinates) is inside the visible shape, else nil.
    func hitTestForTesting(_ p: CGPoint) -> NSView? {
        guard let c = hitContainer else { return nil }
        return NotchHitShape.contains(p, in: c.bounds, inward: c.inwardSide, radius: c.radius) ? c : nil
    }
}
