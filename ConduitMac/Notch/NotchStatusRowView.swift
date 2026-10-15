import SwiftUI

/// One row. Text that came from the gateway or the agent is already sanitized (see
/// `MacUntrustedText`) and is drawn with `Text(verbatim:)`. An approval row leads with
/// the payload (what is being approved); the session title is a secondary line.
struct NotchStatusRowView: View {
    let row: NotchRow
    @ObservedObject var model: NotchStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusDot
                headline
                Spacer(minLength: 0)
                if row.canDismiss {
                    Button { model.onDismissRow(row.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("Dismiss"))
                }
            }
            inline
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.onOpenRow(row) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityValue(content?.summary ?? "")
    }

    private var content: NotchApprovalContent? {
        if case .approval(_, let content) = row.inline { return content }
        return nil
    }

    @ViewBuilder private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            if content != nil {
                // Fixed, localized words only: nothing here is agent-worded.
                Text("Approval needed").font(.callout.weight(.medium)).lineLimit(1)
            } else {
                Text(verbatim: row.title).font(.callout.weight(.medium)).lineLimit(1)
                if let detail = row.detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(detailColor).lineLimit(2)
                }
            }
        }
    }

    private var rowAccessibilityLabel: String {
        if let content {
            // The command leads, as on screen. The description is agent-worded: it is the value, after the command.
            return AppLocalization.string("Approval needed: \(content.command)")
        }
        return row.title
    }

    private var detailColor: Color { row.tone == .failed ? NotchPalette.failure : NotchPalette.secondary }

    private var statusDot: some View {
        Group {
            switch (row.section, row.tone) {
            case (.done, .failed): Image(systemName: "xmark.circle.fill").foregroundStyle(NotchPalette.failure)
            case (.done, _): Image(systemName: "checkmark.circle.fill").foregroundStyle(NotchPalette.secondary)
            case (.needsYou, _): Circle().fill(NotchPalette.attention).frame(width: 8, height: 8)
            default: ProgressView().controlSize(.mini)
            }
        }.accessibilityHidden(true)
    }

    @ViewBuilder private var inline: some View {
        switch row.inline {
        case .none: EmptyView()
        case .answerInConduit:
            Text("Answer in Conduit").font(.caption).foregroundStyle(NotchPalette.attention)
        case .openToAnswer:
            Text("Open in Conduit to answer").font(.caption).foregroundStyle(NotchPalette.attention)
        case .approval(let choices, let content):
            approval(choices, content)
        }
    }

    private func approval(_ choices: NotchApprovalChoices, _ content: NotchApprovalContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = content.summary {
                Text(verbatim: summary).font(.caption).foregroundStyle(NotchPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No line limit: Allow is offered only for a command that is on screen in full (at most
            // `commandLimit` characters, so a few lines); a clipped command would look complete.
            Text(verbatim: content.command).font(.system(.caption, design: .monospaced))
                .foregroundStyle(NotchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The chat title is agent-controlled: secondary, after the payload, never a button label.
            Text(verbatim: row.title).font(.caption2).foregroundStyle(NotchPalette.secondary).lineLimit(1)
            if content.needsReview {
                Text("Too long or unusual to approve here. Review it in Conduit.")
                    .font(.caption).foregroundStyle(NotchPalette.attention)
            }
            if model.failedRows.contains(row.id) {
                Text("Couldn't send. Open in Conduit.").font(.caption).foregroundStyle(NotchPalette.failure)
            }
            HStack(spacing: 8) {
                ForEach(choices.inlineActions(needsReview: content.needsReview), id: \.self) { action in
                    Button(action.label) { model.onAction(row, action) }
                        .buttonStyle(NotchActionButtonStyle(fill: action == .deny ? .failure : .attention))
                        .disabled(!model.canChoose(rowID: row.id))   // 600 ms click guard; never the default key
                }
                let menu = choices.menuActions(needsReview: content.needsReview)
                if !menu.isEmpty {
                    Menu {
                        ForEach(menu, id: \.self) { action in
                            Button(action.label) { model.onAction(row, action) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel(AppLocalization.string("More options"))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(!model.canChoose(rowID: row.id))
                }
            }
        }
    }
}

/// The Allow / Deny buttons. The system `.bordered` style ignores `.tint` on macOS and draws a
/// neutral grey pad about 1.1:1 against the surface in every style, so the buttons were found by
/// their label alone. This one paints the ink itself as the fill (attention for Allow, failure for
/// Deny) with a label chosen for the fill, so the button edge holds 3:1 against the surface and the
/// label 4.5:1 against the fill, in light and dark (`NotchPalette.onAccent`, tested in
/// `NotchStatusViewTests`). The 600 ms click guard disables it; a disabled button is dimmed.
struct NotchActionButtonStyle: ButtonStyle {
    let fill: NotchPalette.Ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(NotchPalette.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 3)
            .background(NotchPalette.color(fill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
