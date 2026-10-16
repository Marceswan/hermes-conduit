import SwiftUI

/// A popped-out session (D21): banner, transcript, composer. AppState is in the
/// environment only for MessageBubble (profile names, media); the session state
/// is the controller's.
struct MacSessionWindowView: View {
    @ObservedObject var controller: MacSessionWindowController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let banner = Self.bannerText(for: controller.phase, profileName: { appState.profileDisplayName($0) }) {
                MacSessionWindowBanner(text: banner, phase: controller.phase,
                                       onRetry: { controller.retry() },
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.transcript.messages) { message in
                        row(message).id(message.id)
                    }
                    if !controller.transcript.streamingText.isEmpty {
                        StreamingBubble(text: controller.transcript.streamingText, active: true).id("streaming")
                    }
                }
                .padding(16)
            }
            .onChange(of: controller.transcript.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: controller.transcript.streamingText) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
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
        default:
            MessageBubble(message: message, gatewayResolver: appState.gatewayMediaResolver)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: String? = controller.transcript.streamingText.isEmpty ? controller.transcript.messages.last?.id : "streaming"
        guard let target else { return }
        proxy.scrollTo(target, anchor: .bottom)
    }

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
