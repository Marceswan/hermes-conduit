import AppKit
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

/// Gives one main window its find controller: injected through the
/// environment (rows and the bar slot read it), registered for the `NSWindow`
/// (menu commands read it), bound to `AppState` for the transcript. The
/// controller is `@State`, not observed: keystrokes must not rebuild rootContent.
struct MacChatFindHost: ViewModifier {
    let appState: AppState
    @State private var controller = MacChatFindController()

    func body(content: Content) -> some View {
        content
            .environment(\.macChatFindController, controller)
            .background(MacChatFindWindowReader(controller: controller))
            .task { controller.bind(to: appState) }
    }
}

extension View {
    func macChatFind(appState: AppState) -> some View {
        modifier(MacChatFindHost(appState: appState))
    }
}

struct MacChatFindWindowReader: NSViewRepresentable {
    let controller: MacChatFindController

    func makeNSView(context: Context) -> ReaderView { ReaderView(controller: controller) }
    func updateNSView(_ view: ReaderView, context: Context) { view.controller = controller }

    final class ReaderView: NSView {
        var controller: MacChatFindController

        init(controller: MacChatFindController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MacChatFindControllers.register(controller, in: window) }
        }
    }
}
