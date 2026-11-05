import CoreGraphics

/// Tells a click from a drag. Pointer positions are in screen coordinates.
struct MacPanelDragTracker {
    var threshold: CGFloat = 4
    private var startPointer: CGPoint?
    private var startFrame: CGRect = .zero
    private(set) var isDragging = false

    init(threshold: CGFloat = 4) {
        self.threshold = threshold
    }

    mutating func begin(pointer: CGPoint, frame: CGRect) {
        startPointer = pointer
        startFrame = frame
        isDragging = false
    }

    /// nil while the pointer is still within `threshold` of the press (a click);
    /// from the first move past it, the frame the panel should have.
    mutating func move(to pointer: CGPoint) -> CGRect? {
        guard let startPointer else { return nil }
        let dx = pointer.x - startPointer.x
        let dy = pointer.y - startPointer.y
        if !isDragging {
            guard (dx * dx + dy * dy).squareRoot() >= threshold else { return nil }
            isDragging = true
        }
        return startFrame.offsetBy(dx: dx, dy: dy)
    }

    /// Whether a drag happened (so the mouse-up must not count as a click). Resets.
    mutating func end() -> Bool {
        defer { startPointer = nil; isDragging = false }
        return isDragging
    }
}
