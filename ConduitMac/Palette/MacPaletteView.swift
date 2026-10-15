import AppKit
import SwiftUI

enum MacPaletteMetrics {
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 32
    static let maxVisibleRows = 9
}

/// The Cmd-K overlay (D18): scrim, search field, result list. Attached around
/// RootView in ConduitMacApp, so a sheet on the window covers it.
struct MacPaletteView: View {
    @ObservedObject var store: MacPaletteStore
    @FocusState private var searchFocused: Bool

    init(store: MacPaletteStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    var body: some View {
        Group {
            if store.isPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { store.dismiss() }
                        .accessibilityHidden(true)
                    panel.padding(.top, 72)
                }
                // Everything behind the palette is inert while it is open, and
                // VoiceOver should treat it that way too.
                .accessibilityAddTraits(.isModal)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: MacPaletteMetrics.width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
            store.move(press.modifiers.contains(.command) ? .first : .up); return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
            store.move(press.modifiers.contains(.command) ? .last : .down); return .handled
        }
        .onKeyPress(.home, phases: .down) { _ in store.move(.first); return .handled }
        .onKeyPress(.end, phases: .down) { _ in store.move(.last); return .handled }
        .onKeyPress(.escape, phases: .down) { _ in store.handleEscape(); return .handled }
        .onKeyPress(.tab, phases: [.down, .repeat]) { _ in .handled }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            // onSubmit, not a raw Return handler: Return that confirms an IME
            // composition must not run the row.
            TextField(AppLocalization.string("Search commands, chats and profiles"), text: $store.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { store.runSelected() }
                .accessibilityLabel(AppLocalization.string("Command palette search"))
                .accessibilityAddTraits(.isSearchField)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var results: some View {
        let rows = store.rows
        return Group {
            if let confirmation = store.pendingConfirmation {
                MacPaletteConfirmCard(
                    confirmation: confirmation,
                    onConfirm: { store.confirmPending() },
                    onCancel: { store.cancelPending() }
                )
            } else if rows.isEmpty {
                Text(AppLocalization.string("No results"))
                    .foregroundStyle(MacPaletteRow.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: MacPaletteMetrics.rowHeight * 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AppLocalization.string("No results"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(store.sections.enumerated()), id: \.offset) { _, section in
                                if let title = section.title {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MacPaletteRow.secondaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(section.items) { item in
                                    MacPaletteRow(item: item, isSelected: item.id == store.selectionID) {
                                        store.run(item)
                                    }
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: MacPaletteMetrics.rowHeight * CGFloat(MacPaletteMetrics.maxVisibleRows) + 24)
                    .onChange(of: store.selectionID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        // Focus stays in the search field while the arrows move the highlight,
        // so VoiceOver would say nothing: speak the row the user moved to.
        // Typing resets the highlight silently (it would talk over the echo).
        .onChange(of: store.navigationToken) { _, _ in
            guard let id = store.selectionID, let item = store.rows.first(where: { $0.id == id }) else { return }
            AccessibilityNotification.Announcement(MacPaletteRow.label(for: item)).post()
        }
    }
}

/// The second step for a hard-to-undo row. Return (the field's onSubmit)
/// confirms, Esc or typing goes back; the buttons are for the mouse.
private struct MacPaletteConfirmCard: View {
    let confirmation: MacPaletteConfirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(confirmation.title).font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(confirmation.message)
                .font(.callout)
                .foregroundStyle(MacPaletteRow.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(AppLocalization.string("Press Return to confirm or Esc to go back."))
                    .font(.caption)
                    .foregroundStyle(MacPaletteRow.secondaryText)
                Spacer(minLength: 8)
                Button(AppLocalization.string("Cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35)))
                    .contentShape(Capsule())
                Button(confirmation.confirmTitle, action: onConfirm)
                    .buttonStyle(.plain)
                    .foregroundStyle(MacPaletteRow.selectedText(scheme))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.conduitAccent))
                    .contentShape(Capsule())
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement("\(confirmation.title) \(confirmation.message)").post()
        }
    }
}

struct MacPaletteRow: View {
    let item: MacPaletteItem
    let isSelected: Bool
    let onRun: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// Text on the accent fill, the rule `MacSessionTabButton` uses (D11):
    /// dark on the light amber, white on the light-mode brown (black at 85%
    /// there is 3.4:1; white is 5.6:1).
    static func selectedText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.85) : Color.white
    }

    /// Subtitles, reasons and headers. The system `.secondary` is about
    /// 3.8:1 on the light window background; primary at 70% clears 4.5:1 in
    /// both appearances (MacPaletteContrastTests).
    static let secondaryText = Color.primary.opacity(secondaryOpacity)
    static let secondaryOpacity = 0.7
    /// Subtitle on the accent fill: white at 75% over the light-mode brown is
    /// 3.9:1; 90% is 4.8:1.
    static let selectedSecondaryOpacity = 0.9

    static func label(for item: MacPaletteItem) -> String {
        [item.title, item.subtitle, item.disabledReason, item.isUnread ? AppLocalization.string("Unread") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        let dim = item.isEnabled || item.isCurrent ? 1.0 : 0.45
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).opacity(dim).accessibilityHidden(true)
            Text(item.title).lineLimit(1).layoutPriority(1).opacity(dim)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).lineLimit(1).opacity(dim)
                    .foregroundStyle(isSelected ? Self.selectedText(scheme).opacity(Self.selectedSecondaryOpacity) : Self.secondaryText)
            }
            Spacer(minLength: 0)
            if item.isCurrent { Image(systemName: "checkmark").accessibilityHidden(true) }
            // Not dimmed: it explains why the row is dimmed.
            if let reason = item.disabledReason {
                Text(reason).font(.caption)
                    .foregroundStyle(isSelected ? Self.selectedText(scheme).opacity(Self.selectedSecondaryOpacity) : Self.secondaryText)
            }
            // The accent fill hides an accent dot, so the selected row draws it in its text colour.
            if item.isUnread {
                Circle().fill(isSelected ? Self.selectedText(scheme) : Color.conduitAccent)
                    .frame(width: 6, height: 6).accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: MacPaletteMetrics.rowHeight)
        .foregroundStyle(isSelected ? Self.selectedText(scheme) : Color.primary)
        .background(Capsule().fill(isSelected ? Color.conduitAccent : .clear))
        .contentShape(Capsule())
        .onTapGesture { if item.isEnabled { onRun() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.label(for: item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if item.isEnabled { onRun() } }
        .disabled(!item.isEnabled)
    }

    private var symbol: String {
        switch item.kind {
        case .session: return "bubble.left"
        case .slash: return "slash.circle"
        case .profile: return "person.crop.circle"
        case .model: return "cpu"
        case .pane: return "sidebar.left"
        case .command: return "command"
        }
    }
}
