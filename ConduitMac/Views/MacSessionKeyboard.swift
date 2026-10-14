import AppKit
import SwiftUI

// Keyboard navigation of the sidebar session list (D10). SessionList is a
// plain `List` of Buttons with no selection binding, and its initialiser
// cannot be gated without duplicating the body, so the list stays as is and
// this modifier, appended to its chain, adds a keyboard cursor: Up / Down /
// Home / End move it, Return opens it, and it scrolls into view. Tab and
// Shift-Tab hand the keyboard to the next / previous view in the window.

/// Session ids in the order the sidebar shows them, published by the list so
/// the Go menu's previous / next commands follow the same order and filter.
struct MacSessionOrderKey: FocusedValueKey {
    typealias Value = [String]
}

extension FocusedValues {
    var macSessionOrder: [String]? {
        get { self[MacSessionOrderKey.self] }
        set { self[MacSessionOrderKey.self] = newValue }
    }
}

private struct MacSessionCursorKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row the keyboard cursor is on; nil while the list is not focused.
    var macSessionCursor: String? {
        get { self[MacSessionCursorKey.self] }
        set { self[MacSessionCursorKey.self] = newValue }
    }
}

/// Appended to the session `List`'s modifier chain.
struct MacSessionListKeyboard: ViewModifier {
    /// Rows the user can see, top to bottom.
    let ids: [String]
    /// The open session, where the cursor starts from.
    let activeID: String?
    let open: (String) -> Void
    @ObservedObject var requests: MacFocusRequests = .shared

    @State private var cursor: String?
    @State private var host = HostWindow()
    @FocusState private var listFocused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .background(HostWindowReader(host: host))
                .focused($listFocused)
                .environment(\.macSessionCursor, listFocused ? cursor : nil)
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in move(.up, press) }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in move(.down, press) }
                .onKeyPress(.home, phases: .down) { press in move(.first, press) }
                .onKeyPress(.end, phases: .down) { press in move(.last, press) }
                .onKeyPress(.tab, phases: .down) { press in traverse(press) }
                .onKeyPress(.return, phases: .down) { press in
                    guard Self.isPlain(press), let cursor, ids.contains(cursor) else { return .ignored }
                    open(cursor)
                    return .handled
                }
                .onChange(of: cursor) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
                .onChange(of: ids) { _, new in
                    cursor = MacSessionCursor.reconciled(cursor, in: new)
                }
                .onChange(of: activeID) { _, new in
                    // Opened some other way (click, Cmd-], deep link): the
                    // cursor starts over from the open session.
                    if cursor != new { cursor = nil }
                }
                .onChange(of: listFocused) { _, focused in
                    if focused, cursor == nil, MacSessionCursor.showsOnFocus(NSApp.currentEvent?.type) {
                        cursor = MacSessionCursor.reconciled(activeID, in: ids)
                    }
                }
                .modifier(MacSessionSearchFocus(requests: requests))
                .focusedSceneValue(\.macSessionOrder, ids)
        }
    }

    /// The SwiftUI list swallows Tab instead of passing it up to the window, so
    /// the window's own key view loop (list, search field, composer) is
    /// driven from here. Shift-Tab goes back. Nothing is forced: the loop
    /// holds only what AppKit already lets take the keyboard, so the system
    /// "Keyboard navigation" setting still decides whether buttons are in it.
    private func traverse(_ press: KeyPress) -> KeyPress.Result {
        let held = press.modifiers.intersection([.shift, .control, .option, .command])
        guard let window = host.window else { return .ignored }
        if held.isEmpty {
            window.selectNextKeyView(nil)
        } else if held == .shift {
            window.selectPreviousKeyView(nil)
        } else {
            return .ignored
        }
        return .handled
    }

    /// Arrow and Home / End keys arrive with the numeric-pad and function
    /// flags set, so "no modifiers" means no shift, control, option or command.
    static func isPlain(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.shift, .control, .option, .command])
    }

    private func move(_ move: MacSessionCursor.Move, _ press: KeyPress) -> KeyPress.Result {
        // Shift / Option / Command arrows keep their meaning elsewhere.
        guard Self.isPlain(press), !ids.isEmpty else { return .ignored }
        cursor = MacSessionCursor.moved(move, from: cursor ?? activeID, in: ids)
        return .handled
    }
}

/// The window hosting the list, for the key view loop.
final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ReaderView)?.host = host
        host.window = view.window
    }

    private final class ReaderView: NSView {
        var host: HostWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

/// Appended to each session row: a ring around the row under the keyboard
/// cursor. An overlay on the row content, so swipe actions, the context menu
/// and hit testing are untouched.
struct MacSessionCursorRow: ViewModifier {
    let id: String
    @Environment(\.macSessionCursor) private var cursor

    func body(content: Content) -> some View {
        content.overlay {
            if cursor == id {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.conduitAccent, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.conduitAccent.opacity(0.10))
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Cmd-F: focuses the "Search sessions" field. macOS 15 has the SwiftUI
/// binding; macOS 14 falls back to the field in the window toolbar.
struct MacSessionSearchFocus: ViewModifier {
    @ObservedObject var requests: MacFocusRequests

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(SwiftUISearchFocus(requests: requests))
        } else {
            content.modifier(ToolbarSearchFocus(requests: requests))
        }
    }

    @available(macOS 15.0, *)
    private struct SwiftUISearchFocus: ViewModifier {
        @ObservedObject var requests: MacFocusRequests
        @FocusState private var searchFocused: Bool

        func body(content: Content) -> some View {
            content
                .searchFocused($searchFocused)
                .onChange(of: requests.searchToken) { _, _ in
                    if requests.consumeSearch() { focus() }
                }
                .onAppear {
                    // The sidebar was not mounted when the command ran.
                    if requests.consumeSearch() { DispatchQueue.main.async { focus() } }
                }
        }

        private func focus() {
            searchFocused = true
            // A sidebar still opening has no field to focus yet: ask again
            // once it has settled (setting true twice is harmless).
            if requests.searchRevealedSidebar {
                DispatchQueue.main.asyncAfter(deadline: .now() + MacFocusRequests.sidebarRevealDelay) { searchFocused = true }
            }
        }
    }

    private struct ToolbarSearchFocus: ViewModifier {
        @ObservedObject var requests: MacFocusRequests

        func body(content: Content) -> some View {
            content
                .onChange(of: requests.searchToken) { _, _ in
                    if requests.consumeSearch() { focus() }
                }
                .onAppear {
                    if requests.consumeSearch() { DispatchQueue.main.async { focus() } }
                }
        }

        private func focus() {
            MacToolbarSearch.focus(in: NSApp.keyWindow)
            if requests.searchRevealedSidebar {
                DispatchQueue.main.asyncAfter(deadline: .now() + MacFocusRequests.sidebarRevealDelay) {
                    MacToolbarSearch.focus(in: NSApp.keyWindow)
                }
            }
        }
    }
}

/// The search field SwiftUI puts in the window toolbar for `.searchable`.
enum MacToolbarSearch {
    @discardableResult
    static func focus(in window: NSWindow?) -> Bool {
        guard let field = searchField(in: window) else { return false }
        return window?.makeFirstResponder(field) ?? false
    }

    static func searchField(in window: NSWindow?) -> NSSearchField? {
        // The toolbar lives in the frame view beside the content view, so the
        // content's own fields are not candidates.
        guard let content = window?.contentView, let frame = content.superview else { return nil }
        for sub in frame.subviews where sub !== content {
            if let found = firstSearchField(in: sub) { return found }
        }
        return nil
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = firstSearchField(in: sub) { return found }
        }
        return nil
    }
}
