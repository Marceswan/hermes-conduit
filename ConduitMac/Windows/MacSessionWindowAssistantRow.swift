import AppKit
import SwiftUI

/// An assistant row in a session window (D21). Upstream's `AssistantBubble` carries Quote, Branch,
/// React and Read aloud, which call the MAIN window's AppState (`replyInComposer`,
/// `branchFromAssistantMessage`, `react`, `toggleReadAloud`): in a session window they would drop a
/// chip into the main composer or branch the main chat. This row renders the same settled content
/// (`SettledAssistantMessageContent`, so the look and Markdown are upstream's) with a Mac-owned
/// action row that has Copy only.
struct MacWindowAssistantRow: View {
    let message: ChatMessage
    let profile: String
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// Injectable so a test never touches the user's clipboard.
    var pasteboard: NSPasteboard = .general
    @EnvironmentObject private var appState: AppState
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    /// The only controls this row offers (the accessibility tree is pinned to it by a test).
    static let actionLabels = ["Copy response"]

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettledAssistantMessageContent(
                message: message,
                identity: .workspace(
                    name: appState.profileDisplayName(profile),
                    photoURL: appState.profileAvatarURL(for: profile)),
                gatewayResolver: gatewayResolver,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize)
                .equatable()
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Button {
                    Self.copy(message.content, to: pasteboard)
                    copied = true
                    resetTask?.cancel()
                    resetTask = Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.conduitAccent : Color.secondary)
                .accessibilityLabel(copied ? AppLocalization.string("Response copied") : AppLocalization.string("Copy response"))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { resetTask?.cancel() }
    }
}

/// Whether a transcript that grew should scroll to its end (D21). A reader who scrolled up to look
/// at something stays where they are while the reply streams; one who is at the bottom follows it,
/// and sending always follows.
struct MacTranscriptFollowPolicy: Equatable {
    /// Driven by a sentinel at the end of the transcript (appeared / disappeared).
    private(set) var bottomVisible = true

    mutating func bottomVisibilityChanged(_ visible: Bool) { bottomVisible = visible }

    func shouldFollow(userJustSent: Bool) -> Bool { userJustSent || bottomVisible }
}
