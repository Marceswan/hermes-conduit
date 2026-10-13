import AppKit

public extension NSView {
    /// UIView.setNeedsDisplay(): upstream's Metal orb renderer redraws a paused MTKView with it.
    func setNeedsDisplay() { needsDisplay = true }
}
