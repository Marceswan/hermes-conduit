import AppKit
import SwiftUI

/// Every Mac sheet has a visible way out. Upstream sheets close by swipe on
/// iOS, so many show no Cancel, Close or Done control and on Mac only Esc
/// closed them. Such a sheet gets the sheet header's X in its top-trailing
/// corner, and a click on the window behind it closes it too. A sheet with
/// its own control keeps that as the only way out, so a stray click never
/// throws away a half-filled form.
///
/// Closing goes through `cancelOperation(_:)` on the sheet window: SwiftUI's
/// sheet window implements it as its dismiss, the same path as Esc from a
/// focused field, so the presenting binding resets.
@MainActor
enum SheetCloseButton {
    private static var observer: NSObjectProtocol?
    private static var monitor: Any?
    /// Sheets already checked, so a sheet that becomes key again (a nested
    /// sheet closed) is not checked twice.
    private static let checked = NSHashTable<NSWindow>.weakObjects()
    private static let decorated = NSHashTable<NSWindow>.weakObjects()
    /// Long enough for the sheet's content to lay out, so the check sees its
    /// own controls.
    static let checkDelay: TimeInterval = 0.25

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { sheetBecameKey(window) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleOutsideClick(event) ? nil : event
        }
    }

    static func sheetBecameKey(_ window: NSWindow) {
        guard isClosableSheet(window), !checked.contains(window) else { return }
        checked.add(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak window] in
            guard let window, window.sheetParent != nil else { return }
            decorateIfNeeded(window)
        }
    }

    /// Adds the X when the sheet shows no Cancel, Close or Done control.
    @discardableResult
    static func decorateIfNeeded(_ window: NSWindow) -> Bool {
        guard isClosableSheet(window), !decorated.contains(window),
              !SheetEscape.hasDismissControl(in: window),
              let frame = window.contentView?.superview else { return false }
        let button = NSHostingView(rootView: CloseButtonView { [weak window] in window.map(close) })
        // Placed by frame and autoresizing, not constraints: a constraint in
        // the window's frame view moved SwiftUI's content view, cutting off
        // the top of a sheet taller than its window. Placed in the frame view,
        // not the content view, which can run past the window's edges.
        let size = button.fittingSize
        let inset: CGFloat = 10
        let bounds = frame.bounds
        let y = frame.isFlipped ? bounds.minY + inset : bounds.maxY - inset - size.height
        button.frame = NSRect(x: bounds.maxX - inset - size.width, y: y, width: size.width, height: size.height)
        button.autoresizingMask = [.minXMargin, frame.isFlipped ? .maxYMargin : .minYMargin]
        // Above the content and the sheet's title bar views.
        frame.addSubview(button)
        decorated.add(window)
        return true
    }

    static func isDecorated(_ window: NSWindow) -> Bool { decorated.contains(window) }

    static func close(_ window: NSWindow) {
        window.cancelOperation(nil)
    }

    /// A click in the content of the window behind a decorated sheet closes
    /// the sheet. The title bar keeps working: drag, close, zoom.
    static func handleOutsideClick(_ event: NSEvent) -> Bool {
        guard let parent = event.window, let sheet = parent.attachedSheet,
              sheet.attachedSheet == nil, decorated.contains(sheet),
              parent.contentLayoutRect.contains(event.locationInWindow) else { return false }
        close(sheet)
        return true
    }

    /// A SwiftUI sheet whose window can dismiss itself; open/save panels and
    /// alerts are left alone.
    private static func isClosableSheet(_ window: NSWindow) -> Bool {
        window.sheetParent != nil && SheetEscape.isSwiftUIHosted(window)
            && window.responds(to: #selector(NSResponder.cancelOperation(_:)))
    }
}

/// The sheet header's X (ConduitSheetHeader), sized for a pointer.
private struct CloseButtonView: View {
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .conduitGlassControl(cornerRadius: 13)
        .help(AppLocalization.string("Close"))
        .accessibilityLabel(AppLocalization.string("Close"))
    }
}
