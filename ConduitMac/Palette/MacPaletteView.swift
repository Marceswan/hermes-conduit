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
                .transition(.opacity)
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
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var results: some View {
        let rows = store.rows
        return Group {
            if rows.isEmpty {
                Text(AppLocalization.string("No results"))
                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
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
    }
}

private struct MacPaletteRow: View {
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).accessibilityHidden(true)
            Text(item.title).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).lineLimit(1).foregroundStyle(isSelected ? Self.selectedText(scheme).opacity(0.75) : .secondary)
            }
            Spacer(minLength: 0)
            if item.isCurrent { Image(systemName: "checkmark").accessibilityHidden(true) }
            if let reason = item.disabledReason { Text(reason).font(.caption).foregroundStyle(isSelected ? Self.selectedText(scheme).opacity(0.75) : .secondary) }
            if item.isUnread { Circle().fill(Color.conduitAccent).frame(width: 6, height: 6).accessibilityHidden(true) }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: MacPaletteMetrics.rowHeight)
        .foregroundStyle(isSelected ? Self.selectedText(scheme) : Color.primary)
        .background(Capsule().fill(isSelected ? Color.conduitAccent : .clear))
        .opacity(item.isEnabled || item.isCurrent ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { onRun() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        [item.title, item.subtitle, item.disabledReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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
