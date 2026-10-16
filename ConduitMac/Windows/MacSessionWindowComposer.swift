import SwiftUI

/// The session window's composer (D21): Return sends, Shift-Return inserts a newline.
/// No slash commands, mentions, voice or attachments in v1; a busy turn shows Stop.
struct MacSessionWindowComposer: View {
    enum PrimaryAction: Equatable { case send, stop }

    @ObservedObject var controller: MacSessionWindowController
    @State private var focused = true
    @State private var height = ComposerPasteTextView.minimumHeight
    @State private var editorID = UUID()
    @State private var showsImageNotice = false
    @State private var noticeTask: Task<Void, Never>?

    static func primaryAction(for controller: MacSessionWindowController) -> PrimaryAction {
        controller.transcript.turn != .idle ? .stop : .send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = controller.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                field
                primaryButton
            }
            if showsImageNotice {
                Text(AppLocalization.string("Images can't be attached in this window."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { noticeTask?.cancel() }
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if controller.draft.isEmpty {
                Text(AppLocalization.string("Message"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            ComposerPasteTextView(
                text: $controller.draft,
                isFocused: $focused,
                measuredHeight: $height,
                enabled: controller.phase == .ready,
                onPastedImage: { _ in showImageNotice() },
                onPastedImageError: { _ in showImageNotice() },
                editorIdentity: editorID,
                returnKeySends: true,
                canSubmitFromReturn: controller.canSend,
                onSubmitFromReturn: { controller.send(); return true },
                followsMainRoute: false)
                .frame(height: min(max(height, ComposerPasteTextView.minimumHeight), ComposerPasteTextView.maximumHeight))
        }
        .conduitGlassSurface(cornerRadius: 16)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch Self.primaryAction(for: controller) {
        case .send:
            Button { controller.send() } label: {
                Image(systemName: "paperplane.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.conduitAccent)
            .disabled(!controller.canSend)
            .accessibilityLabel(AppLocalization.string("Send"))
        case .stop:
            Button { controller.stopTurn() } label: {
                Image(systemName: "stop.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.conduitAccent)
            .disabled(controller.phase != .ready)
            .accessibilityLabel(AppLocalization.string("Stop"))
        }
    }

    private func showImageNotice() {
        showsImageNotice = true
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showsImageNotice = false
        }
    }
}
