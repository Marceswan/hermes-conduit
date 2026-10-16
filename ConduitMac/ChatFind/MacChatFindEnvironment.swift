import SwiftUI

private struct MacChatFindControllerKey: EnvironmentKey {
    static let defaultValue: MacChatFindController? = nil
}

private struct MacChatFindMessageIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The window's find controller; nil in every window that has no whole-chat find.
    var macChatFindController: MacChatFindController? {
        get { self[MacChatFindControllerKey.self] }
        set { self[MacChatFindControllerKey.self] = newValue }
    }

    /// The transcript message the text views below belong to; nil outside a row.
    var macChatFindMessageID: String? {
        get { self[MacChatFindMessageIDKey.self] }
        set { self[MacChatFindMessageIDKey.self] = newValue }
    }
}

/// The one hook ChatView carries (D23): tags a transcript row with its message
/// id so every `SelectableTextView` below registers for highlighting, and hands
/// the scroll engine to the find controller. With no controller in the
/// environment (every other window) it adds nothing.
struct MacChatFindRowModifier: ViewModifier {
    let id: String
    let engine: ChatScrollEngine
    @Environment(\.macChatFindController) private var controller

    func body(content: Content) -> some View {
        content
            .environment(\.macChatFindMessageID, controller == nil ? nil : id)
            .onAppear { controller?.attach(engine: engine) }
    }
}

extension View {
    func macChatFindRow(id: String, engine: ChatScrollEngine) -> some View {
        modifier(MacChatFindRowModifier(id: id, engine: engine))
    }
}
