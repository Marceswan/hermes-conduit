import AppKit
import SwiftUI

enum MacQuickAskPanelConfig {
    static func make(onDismiss: @escaping () -> Void) -> MacFloatingPanelConfig {
        MacFloatingPanelConfig(
            size: NSSize(width: 640, height: 72),
            maxHeight: 480,
            placement: .screenCenterTopFraction(0.22),
            canBecomeKey: true,
            dismissOnResignKey: true,
            dismissOnEscape: true,
            onDismiss: onDismiss,
            accessibilityLabel: AppLocalization.string("Quick Ask"))
    }
}

/// The panel's content (D15): one glass layer, no nested glass (D7).
struct MacQuickAskView: View {
    @ObservedObject var controller: MacQuickAskController
    var onHeight: (CGFloat) -> Void
    @FocusState private var fieldFocused: Bool
    @State private var windowBox = MacQuickAskWindowBox()

    private var model: MacQuickAskModel { controller.model }
    private var connected: Bool { controller.connection == .connected }
    private var needsInput: Bool {
        if case .needsInput = model.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !connected { connectionStrip }
            TextField(AppLocalization.string("Ask Hermes"), text: $controller.draft)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .disabled(!connected || model.isTurnRunning || needsInput)
                .onSubmit { controller.submit() }
                .accessibilityLabel(AppLocalization.string("Ask Hermes"))
            if !model.text.isEmpty {
                ScrollView {
                    MarkdownText(source: model.text, isStreaming: model.isTurnRunning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            statusArea
            footer
        }
        .padding(16)
        .frame(width: 640)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MacQuickAskHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(MacQuickAskHeightKey.self) { onHeight($0) }
        .conduitGlassSurface(cornerRadius: 16)
        .background { hiddenShortcuts }
        .background(MacQuickAskWindowReader(box: windowBox))
        .onAppear { refocusField() }
        // A reopened panel keeps its view, so onAppear does not fire again.
        .onChange(of: controller.focusRequest) { _, _ in refocusField() }
        // The field is disabled while a turn runs; give it back when the turn ends.
        .onChange(of: model.isTurnRunning) { _, running in
            if !running { DispatchQueue.main.async { fieldFocused = true } }
        }
    }

    /// A freshly shown non-activating panel has the window itself as first
    /// responder, and SwiftUI cannot move focus into a field from there. Hand
    /// the hosting view first responder, then ask for the field.
    private func refocusField() {
        DispatchQueue.main.async {
            if let window = windowBox.window, window.firstResponder === window {
                window.makeFirstResponder(window.contentView)
            }
            fieldFocused = false
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var connectionStrip: some View {
        HStack {
            Text(controller.connection == .connecting
                 ? AppLocalization.string("Reconnecting")
                 : AppLocalization.string("Not connected"))
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("Open Conduit")) { controller.openConduit() }
                .controlSize(.small)
        }
    }

    @ViewBuilder private var statusArea: some View {
        switch model.state {
        case .streaming(_, let status?):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .needsInput:
            Text(AppLocalization.string("Hermes needs your input")).font(.callout)
        case .failed(let message, _, let kind):
            HStack {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if kind == .sessionLimit {
                    Button(AppLocalization.string("Open Conduit")) { controller.openConduit() }
                        .controlSize(.small)
                }
                Button(AppLocalization.string("Retry")) { controller.retry() }
                    .controlSize(.small)
            }
        default:
            EmptyView()
        }
        if model.isTurnRunning, controller.connection != .connected {
            Text(AppLocalization.string("Connection lost. The reply may still finish; open it in Conduit."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.promoteID != nil {
            HStack {
                if model.isTurnRunning {
                    Button(AppLocalization.string("Stop")) { controller.stop() }
                        .controlSize(.small)
                }
                Spacer()
                if needsInput {
                    openInConduitButton.buttonStyle(.borderedProminent)
                } else {
                    openInConduitButton.buttonStyle(.bordered)
                }
            }
        }
    }

    private var openInConduitButton: some View {
        Button(AppLocalization.string("Open in Conduit")) { controller.promote() }
            .keyboardShortcut(.return, modifiers: .command)
            .controlSize(.small)
    }

    /// Cmd-. and Cmd-N work while the field has focus; the visible Stop
    /// button above carries no shortcut so the key is defined once.
    private var hiddenShortcuts: some View {
        Group {
            Button(AppLocalization.string("Stop")) { controller.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button(AppLocalization.string("New conversation")) { controller.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Holds the panel's window for `refocusField`; weak, set by the reader.
@MainActor
private final class MacQuickAskWindowBox {
    weak var window: NSWindow?
}

private struct MacQuickAskWindowReader: NSViewRepresentable {
    let box: MacQuickAskWindowBox

    final class Reader: NSView {
        var box: MacQuickAskWindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            MainActor.assumeIsolated { box?.window = window }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.box = box
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.box = box }
}

private struct MacQuickAskHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Lets the view report its height to a panel that is created after the view.
@MainActor
private final class MacQuickAskPanelRef {
    weak var panel: MacFloatingPanelController?
}

extension MacQuickAskController {
    /// The real panel: shared-base MacFloatingPanelController around MacQuickAskView.
    func installDefaultPanel() {
        makePanel = { controller in
            let ref = MacQuickAskPanelRef()
            let config = MacQuickAskPanelConfig.make { [weak controller] in
                controller?.panelDidDismiss()
            }
            let host = MacFloatingPanelController(config: config) {
                MacQuickAskView(controller: controller) { height in ref.panel?.updateContentHeight(height) }
            }
            ref.panel = host
            return host
        }
    }
}
