import SwiftUI

/// A popped-out session (D21): banner, transcript, composer. AppState is in the
/// environment only for the reused upstream views (MessageBubble for non-assistant rows,
/// the settled assistant content: profile names, media); the session state is the
/// controller's. Assistant rows get a Mac-owned Copy-only action row (`MacWindowAssistantRow`),
/// because upstream's Quote, Branch, React and Read aloud act on the main window's AppState.
struct MacSessionWindowView: View {
    @ObservedObject var controller: MacSessionWindowController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var follow = MacTranscriptFollowPolicy()

    static let bottomAnchorID = "bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            if let banner = Self.bannerText(for: controller.phase, profileName: { appState.profileDisplayName($0) }) {
                MacSessionWindowBanner(text: banner, phase: controller.phase,
                                       onRetry: { Self.retry(controller) },
                                       onClose: { dismissWindow() })
            }
            transcript
            Divider()
            MacSessionWindowComposer(controller: controller)
                .padding(12)
        }
        .navigationTitle(controller.title)
        .frame(minWidth: 420, minHeight: 420)
        .background(ConduitBackdrop(drifts: false))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MacSessionWindowTranscriptRows(controller: controller, follow: $follow)
                .padding(16)
            }
            .onChange(of: controller.transcript.messages.count) { old, new in
                let sent = new > old && controller.transcript.messages.last?.role == .user
                if follow.shouldFollow(userJustSent: sent) { scrollToEnd(proxy) }
            }
            .onChange(of: controller.transcript.streamingText) { _, _ in
                if follow.shouldFollow(userJustSent: false) { scrollToEnd(proxy) }
            }
            .onAppear { scrollToEnd(proxy) }
            // View > Zoom (D27): a reader at the end stays at the end. The new level keeps
            // the offset, so the end can leave the view; scroll once the change has settled.
            .onReceive(NotificationCenter.default.publisher(for: MacUIZoom.willChangeNotification)) { _ in
                guard follow.shouldFollow(userJustSent: false) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + NSScrollViewChatSurface.zoomSettleDelay) { scrollToEnd(proxy) }
            }
        }
    }

    static func isVoiceCallMarker(_ message: ChatMessage) -> Bool {
        message.displayKind == VoiceCallChatLink.displayKind || message.displayKind == VoiceCallChatLink.originDisplayKind
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// The banner's Retry for `.failed`: re-reads the session (not `scopeChanged()`).
    static func retry(_ controller: MacSessionWindowController) { controller.retry() }

    static func bannerText(for phase: MacSessionWindowController.Phase, profileName: (String) -> String) -> String? {
        switch phase {
        case .ready: return nil
        case .loading: return AppLocalization.string("Opening conversation…")
        case .disconnected: return AppLocalization.string("Not connected to Hermes")
        case .wrongScope(let profile):
            return String(format: AppLocalization.string("Belongs to %@. Switch to it in the main window to continue."),
                          MacUntrustedText.sanitize(profileName(profile), maxGraphemes: 40))
        case .deleted: return AppLocalization.string("This conversation was deleted.")
        case .failed(let message): return message
        }
    }
}

/// The rows of a session window's transcript. The reused upstream rows (`MessageBubble`, the step
/// and card rows, `StreamingBubble`) read their state and actions from the environment that
/// `.chatRows()` sets, and stop with a precondition failure without it. `.chatRows()` sits once on
/// the stack, as in `ChatView`. A separate view so a test can lay out the rows.
struct MacSessionWindowTranscriptRows: View {
    @ObservedObject var controller: MacSessionWindowController
    @Binding var follow: MacTranscriptFollowPolicy

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(controller.transcript.messages) { message in
                MacSessionWindowRow(message: message, controller: controller).id(message.id)
            }
            if !controller.transcript.streamingText.isEmpty {
                StreamingBubble(text: controller.transcript.streamingText, active: true).id("streaming")
            }
            // The follow sentinel: in view means the reader is at the end.
            Color.clear.frame(height: 1)
                .id(MacSessionWindowView.bottomAnchorID)
                .onAppear { follow.bottomVisibilityChanged(true) }
                .onDisappear { follow.bottomVisibilityChanged(false) }
        }
        .chatRows()
    }
}

/// One transcript row of a session window.
struct MacSessionWindowRow: View {
    let message: ChatMessage
    let controller: MacSessionWindowController
    @EnvironmentObject private var appState: AppState

    @ViewBuilder
    var body: some View {
        switch message.role {
        case .approval:
            if let activity = message.approval {
                MacWindowApprovalCard(activity: activity) { controller.approve(messageID: message.id, choice: $0) }
            }
        case .clarify:
            if let activity = message.clarify {
                MacWindowClarifyCard(activity: activity) { question, answer in
                    controller.answerClarify(messageID: message.id, questionID: question, answer: answer)
                }
            }
        case .inputPrompt:
            if let activity = message.inputPrompt {
                MacWindowInputPromptCard(activity: activity) { controller.answerInputPrompt(messageID: message.id, value: $0) }
            }
        case .assistant:
            MacWindowAssistantRow(message: message, profile: controller.token.profile,
                                  gatewayResolver: appState.gatewayMediaResolver)
        case .system where MacSessionWindowView.isVoiceCallMarker(message):
            // MessageBubble's marker card opens the call transcript in the main window.
            SystemBubble(message: message)
        default:
            MessageBubble(message: message, gatewayResolver: appState.gatewayMediaResolver)
        }
    }
}

/// Status strip above the transcript. Colours follow the cards (orange waiting, red failed).
private struct MacSessionWindowBanner: View {
    let text: String
    let phase: MacSessionWindowController.Phase
    let onRetry: () -> Void
    let onClose: () -> Void

    private var tint: Color {
        switch phase {
        case .failed, .deleted: return .red
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if phase == .loading { ProgressView().controlSize(.small) }
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch phase {
            case .failed: Button(AppLocalization.string("Retry"), action: onRetry)
            case .deleted: Button(AppLocalization.string("Close"), action: onClose)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14))
        .accessibilityElement(children: .contain)
    }
}
