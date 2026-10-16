import AppKit
import SwiftUI

/// The query field. An AppKit `NSSearchField` on purpose: Return vs
/// Shift-Return, Esc and IME composition are decided by `doCommandBy` (which is
/// not called for a marked composition), not by SwiftUI key handlers.
struct MacChatFindField: NSViewRepresentable {
    let controller: MacChatFindController
    /// The controller's `focusToken`, passed in as a value: SwiftUI skips
    /// `updateNSView` when every stored input is unchanged, and the controller
    /// is a reference, so a repeat Cmd-F would otherwise never refocus the field.
    var focusToken = 0

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = AppLocalization.string("Find in chat")
        field.setAccessibilityLabel(AppLocalization.string("Find in chat"))
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.sendsSearchStringImmediately = true
        field.stringValue = controller.query
        controller.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.controller = controller
        controller.field = field
        // Do not fight the user's typing: only mirror the model into an idle field.
        if field.currentEditor() == nil, field.stringValue != controller.query {
            field.stringValue = controller.query
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        if coordinator.controller.field === field { coordinator.controller.field = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        enum Command: Equatable { case next, previous, close }

        var controller: MacChatFindController
        var lastFocusToken = -1

        init(controller: MacChatFindController) {
            self.controller = controller
        }

        /// Pure mapping, so tests need no real key events. A marked (IME)
        /// composition gets nothing: the field editor confirms it.
        static func command(for selector: Selector, hasMarkedText: Bool, shift: Bool) -> Command? {
            guard !hasMarkedText else { return nil }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 NSSelectorFromString("insertNewlineIgnoringFieldEditor:"),
                 NSSelectorFromString("insertLineBreak:"):
                return shift ? .previous : .next
            case #selector(NSResponder.cancelOperation(_:)):
                return .close
            default:
                return nil
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            controller.query = field.stringValue
        }

        /// The search field's own cancel (x) button.
        @objc func fieldAction(_ sender: NSSearchField) {
            controller.query = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            guard let command = Self.command(for: commandSelector, hasMarkedText: textView.hasMarkedText(), shift: shift) else {
                return false
            }
            switch command {
            case .next: controller.next()
            case .previous: controller.previous()
            case .close: controller.close()
            }
            return true
        }
    }
}

/// The strip at the top of the chat pane (D23). Opaque window background with a
/// bottom divider, no second glass layer (D7).
struct MacChatFindBar: View {
    @ObservedObject var controller: MacChatFindController

    private var countLabel: String {
        MacChatFindLabel.text(query: controller.query, state: controller.state)
    }

    var body: some View {
        if controller.isOpen {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MacChatFindField(controller: controller, focusToken: controller.focusToken)
                    .frame(minWidth: 160, maxWidth: 320)
                    .frame(height: 22)
                Text(countLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 64, alignment: .leading)
                Button { controller.previous() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(controller.state.count == 0)
                    .help(Text("Previous match (Shift-Return)"))
                    .accessibilityLabel(Text("Previous match"))
                Button { controller.next() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(controller.state.count == 0)
                    .help(Text("Next match (Return)"))
                    .accessibilityLabel(Text("Next match"))
                if controller.showsLoadedOnlyNote {
                    Text("Loaded messages only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text("Older messages are not loaded. Scroll to the top and choose Load earlier messages to include them."))
                }
                Spacer(minLength: 0)
                Button("Done") { controller.close() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Find in chat"))
            // Focus stays in the field while Return steps through hits, so VoiceOver
            // would say nothing: speak the new count ("3 of 12", "No matches").
            .onChange(of: countLabel) { _, label in
                guard !label.isEmpty else { return }
                AccessibilityNotification.Announcement(label).post()
            }
        }
    }
}

/// Reads the window's controller from the environment: the router overlays
/// this on the chat pane in every window, and only a window with whole-chat
/// find (`macChatFind(appState:)` above it) shows anything.
struct MacChatFindSlot: View {
    @Environment(\.macChatFindController) private var controller

    var body: some View {
        if let controller {
            MacChatFindBar(controller: controller)
        }
    }
}
