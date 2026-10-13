import AppKit

/// Esc closes a sheet on Mac. Upstream's 60 sheets declare no
/// `.cancelAction`, so this presses the sheet's own close/cancel/done
/// control through accessibility and SwiftUI's dismiss path runs as if
/// the user had clicked it.
@MainActor
enum SheetEscape {
    private static var monitor: Any?
    static let escapeKeyCode: UInt16 = 53

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            return handleEscape(in: event.window) ? nil : event
        }
    }

    static func handleEscape(in window: NSWindow?) -> Bool {
        guard let window, window.sheetParent != nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        return withAccessibilityTree {
            guard let control = closeControl(in: window.contentView) else { return false }
            return pressed(control)
        }
    }

    /// SwiftUI builds a window's accessibility tree only while an assistive
    /// client is attached; without one a sheet's hosting view reports no
    /// children. `AXEnhancedUserInterface` is the switch those clients flip,
    /// so hold it on just for the lookup and press, then put it back.
    private static func withAccessibilityTree<T>(_ body: () -> T) -> T {
        let key = "accessibilityEnhancedUserInterface"
        let previous = (NSApp.value(forKey: key) as? Bool) ?? false
        if !previous { NSApp.setValue(true, forKey: key) }
        defer { if !previous { NSApp.setValue(false, forKey: key) } }
        return body()
    }

    /// Breadth-first search for a button whose label starts with a
    /// close/cancel/done word. Bounded so a huge sheet cannot stall a key press.
    static func closeControl(in root: Any?) -> NSObject? {
        var queue: [NSObject] = (root as? NSObject).map { [$0] } ?? []
        var visited = 0
        while !queue.isEmpty, visited < 2_000 {
            let dequeued = queue.removeFirst()
            visited += 1
            guard let node = accessible(dequeued) else { continue }
            // AppKit exposes a control's cell, whose label can differ from the
            // control's; judge and press the control itself.
            let control = (dequeued as? NSCell)?.controlView ?? dequeued
            if isCloseButton(node) || (control !== dequeued && isCloseButton(accessible(control))) {
                return control
            }
            queue.append(contentsOf: (node.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
        }
        return nil
    }

    /// SwiftUI's accessibility nodes answer the accessibility selectors but do
    /// not declare `NSAccessibilityProtocol`, so `as?` rejects them. Message
    /// them directly once they prove they respond.
    private static func accessible(_ object: AnyObject) -> NSAccessibilityProtocol? {
        if let declared = object as? NSAccessibilityProtocol { return declared }
        guard object.responds(to: #selector(NSAccessibilityProtocol.accessibilityRole)),
              object.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)) else { return nil }
        return unsafeBitCast(object, to: NSAccessibilityProtocol.self)
    }

    /// `accessibilityPerformPress()` reports false for AppKit buttons even when
    /// the action ran, so a found control counts as handled once it is pressed.
    private static func pressed(_ control: NSObject) -> Bool {
        guard let node = accessible(control) else { return false }
        _ = node.accessibilityPerformPress()
        return true
    }

    private static func isCloseButton(_ node: NSAccessibilityProtocol?) -> Bool {
        guard let node, node.accessibilityRole() == .button,
              let label = node.accessibilityLabel() ?? node.accessibilityTitle() else { return false }
        return isCloseLabel(label)
    }

    static func isCloseLabel(_ label: String) -> Bool {
        let words = Set(["Close", "Cancel", "Done"].flatMap { [$0, AppLocalization.string(String.LocalizationValue($0))] })
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return words.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") }
    }
}
