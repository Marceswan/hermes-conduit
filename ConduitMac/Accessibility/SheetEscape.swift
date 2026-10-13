import AppKit

/// Esc closes a SwiftUI-hosted sheet on Mac. The shared sheet header carries
/// `.keyboardShortcut(.cancelAction)` (the supported path); this monitor is
/// the fallback for sheets without one. It presses the sheet's own Cancel or
/// Close control through accessibility, so SwiftUI's dismiss path runs as if
/// the user had clicked it. Pressing an enabled, visible control is the same
/// as a mouse click, so `interactiveDismissDisabled` does not block it.
///
/// Never presses "Done" (it can commit, e.g. a model picker saves on Done),
/// and never acts on open/save panels or alerts, which keep their native Esc.
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
        guard let window, window.sheetParent != nil, isSwiftUIHosted(window) else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        return withAccessibilityTree {
            guard let control = closeControl(in: window.contentView) else { return false }
            return pressed(control)
        }
    }

    /// SwiftUI sheets host their content in an `NSHostingController`/hosting
    /// view (the private `SheetHostingView<SheetContent>` in practice).
    static func isSwiftUIHosted(_ window: NSWindow) -> Bool {
        if let controller = window.contentViewController,
           String(reflecting: type(of: controller)).contains("NSHostingController") { return true }
        if let view = window.contentView, String(reflecting: type(of: view)).contains("HostingView") { return true }
        return false
    }

    // MARK: - Accessibility tree

    private static let boostGetter = NSSelectorFromString("accessibilityEnhancedUserInterfaceAttribute")
    private static let boostSetter = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")

    /// True when `app` exposes the enhanced-UI accessors. No KVC: on
    /// `SwiftUI.AppKitApplication` the KVC key raises `NSUnknownKeyException`.
    static func canBoostTree(_ app: NSObject) -> Bool {
        app.responds(to: boostGetter) && app.responds(to: boostSetter)
    }

    static func isTreeBoosted(_ app: NSObject) -> Bool {
        guard app.responds(to: boostGetter) else { return false }
        return (app.perform(boostGetter)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
    }

    private static func setTreeBoosted(_ on: Bool, _ app: NSObject) {
        _ = app.perform(boostSetter, with: NSNumber(value: on))
    }

    /// SwiftUI builds a window's accessibility tree only while an assistive
    /// client is attached; without one a sheet's hosting view reports no
    /// children. `AXEnhancedUserInterface` is the switch those clients flip,
    /// so hold it on just for the lookup and press, then put it back. Already
    /// on (e.g. the hover engine left it on) means touch nothing. If the
    /// accessors are unavailable the body does not run and the result is false.
    static func withAccessibilityTree(on app: NSObject = NSApp, _ body: () -> Bool) -> Bool {
        guard canBoostTree(app) else { return false }
        let previous = isTreeBoosted(app)
        if !previous { setTreeBoosted(true, app) }
        defer { if !previous { setTreeBoosted(false, app) } }
        return body()
    }

    private static let traversalSelectors = ["accessibilityRole", "accessibilityChildren"].map(NSSelectorFromString)
    private static let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
    private static let hiddenSelector = NSSelectorFromString("isAccessibilityHidden")
    private static let pressSelectors = [
        "accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityPerformPress",
        "isAccessibilityEnabled",
    ].map(NSSelectorFromString)

    /// SwiftUI's accessibility nodes answer the accessibility selectors but do
    /// not declare `NSAccessibilityProtocol`, so `as?` rejects them. Message
    /// one only after it proves it responds to every selector in `required`.
    private static func accessible(_ object: AnyObject, requiring required: [Selector]) -> NSAccessibilityProtocol? {
        guard required.allSatisfy({ object.responds(to: $0) }) else { return nil }
        return unsafeBitCast(object, to: NSAccessibilityProtocol.self)
    }

    // MARK: - Matching

    private enum Kind: Int { case cancel = 0, close = 1 }

    /// Breadth-first search for the Cancel or Close control; Cancel wins over
    /// Close. Bounded so a huge sheet cannot stall a key press.
    static func closeControl(in root: Any?) -> NSObject? {
        var queue: [NSObject] = (root as? NSObject).map { [$0] } ?? []
        var visited = 0
        var best: (kind: Kind, control: NSObject)?
        while !queue.isEmpty, visited < 2_000 {
            let dequeued = queue.removeFirst()
            visited += 1
            guard let node = accessible(dequeued, requiring: traversalSelectors) else { continue }
            // AppKit exposes a control's cell, whose label can differ from the
            // control's; judge and press the control itself.
            let control = (dequeued as? NSCell)?.controlView ?? dequeued
            var kind = classify(accessible(dequeued, requiring: pressSelectors))
            if kind == nil, control !== dequeued { kind = classify(accessible(control, requiring: pressSelectors)) }
            if let kind, best == nil || kind.rawValue < best!.kind.rawValue { best = (kind, control) }
            queue.append(contentsOf: (node.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
        }
        return best?.control
    }

    private static func classify(_ node: NSAccessibilityProtocol?) -> Kind? {
        guard let node, node.accessibilityRole() == .button,
              node.isAccessibilityEnabled() else { return nil }
        // SwiftUI's nodes have no `isAccessibilityHidden`; hidden views are
        // pruned from their tree, so only message it where it exists.
        if let object = node as? NSObject, object.responds(to: hiddenSelector), node.isAccessibilityHidden() { return nil }
        let title = node.accessibilityTitle() ?? ""
        guard let text = node.accessibilityLabel() ?? node.accessibilityTitle() else { return nil }
        return kind(forLabel: text, iconOnly: isIconOnly(node, title: title))
    }

    /// SwiftUI nodes report no `accessibilityTitle` even for a button with
    /// visible text, but give an image-only button the symbol name as its
    /// `accessibilityIdentifier` ("xmark" for the header X). So a SwiftUI node
    /// is icon-only when it has that identifier; AppKit controls when their
    /// title is empty. Verified on macOS 26 / SwiftUI in SheetEscapeTests; if
    /// SwiftUI stops synthesizing the identifier the X no longer matches
    /// "Close <title>" and only the header's `.cancelAction` handles Esc.
    private static func isIconOnly(_ node: NSAccessibilityProtocol, title: String) -> Bool {
        guard title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let object = node as? NSObject, !(object is NSControl), !(object is NSCell) else { return true }
        guard object.responds(to: identifierSelector) else { return false }
        return !(node.accessibilityIdentifier() ?? "").isEmpty
    }

    private static let cancelWords = words("Cancel")
    private static let closeWords = words("Close")

    private static func words(_ english: String) -> Set<String> {
        [english, AppLocalization.string(String.LocalizationValue(english))]
    }

    /// Exact "Cancel"; exact "Close"; "Close <anything>" only for an
    /// icon-only button (the sheet header's X, labelled "Close <title>").
    /// Everything else, including "Done" and "Cancel dictation", is no match.
    private static func kind(forLabel label: String, iconOnly: Bool) -> Kind? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if cancelWords.contains(trimmed) { return .cancel }
        if closeWords.contains(trimmed) { return .close }
        if iconOnly, closeWords.contains(where: { trimmed.hasPrefix($0 + " ") }) { return .close }
        return nil
    }

    static func isCloseLabel(_ label: String, iconOnly: Bool = true) -> Bool {
        kind(forLabel: label, iconOnly: iconOnly) != nil
    }

    /// `accessibilityPerformPress()` reports false for AppKit buttons even when
    /// the action ran, so a found control counts as handled once it is pressed.
    private static func pressed(_ control: NSObject) -> Bool {
        guard let node = accessible(control, requiring: pressSelectors) else { return false }
        _ = node.accessibilityPerformPress()
        return true
    }
}
