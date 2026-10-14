import SwiftUI

enum MacSessionTabMetrics {
    static let height: CGFloat = 28
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 220
    /// The strip's width until the toolbar has been measured.
    static let defaultSlotWidth: CGFloat = 360
}

/// The chat toolbar's session tabs (D11), in place of the title pill. The
/// system toolbar platter is the only glass layer (D7): tabs are flat pills.
struct MacSessionTabStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MacSessionTabsStore
    /// The toolbar room around the strip; the principal slot sizes the item to its ideal width.
    @State private var slotWidth: CGFloat = MacSessionTabMetrics.defaultSlotWidth
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void

    /// `store` is injectable for tests; nil is the shared store.
    @MainActor
    init(store: MacSessionTabsStore? = nil,
         onRename: @escaping (SessionSummary) -> Void,
         onDelete: @escaping (SessionSummary) -> Void) {
        self.store = store ?? .shared
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.model.tabs, id: \.id) { tab in
                        MacSessionTabButton(
                            tab: tab,
                            session: appState.sessions.first { $0.macMatches(tab.id) },
                            isActive: tab.id == store.model.activeID,
                            onSelect: { store.select(tab.id) },
                            onClose: { store.close(tab.id) },
                            onRename: onRename,
                            onDelete: onDelete
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, MacSessionTabEdgeFade.width)
            }
            .mask(MacSessionTabEdgeFade())
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: store.model.activeID) { _, _ in scroll(proxy, animated: true) }
        }
        .frame(minWidth: MacSessionTabMetrics.minWidth,
               idealWidth: max(MacSessionTabMetrics.minWidth, slotWidth), maxWidth: .infinity)
        .frame(height: MacSessionTabMetrics.height)
        .background(MacToolbarSlotReader { slotWidth = $0 })
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = store.model.activeID else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct MacSessionTabButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: MacSessionTab
    let session: SessionSummary?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    @State private var hovering = false

    private var title: String { session?.title ?? tab.title }

    private var liveStatus: SessionLiveStatus? {
        guard let session else { return nil }
        if let status = appState.sessionLiveStatus(session) { return status }
        return isActive && appState.isBusy ? .working : nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if let liveStatus {
                MacSessionTabBusyDot(filter: liveStatus == .needsInput ? .needsInput : .working)
            } else if let session, !isActive, appState.isSessionUnread(session) {
                Circle().fill(SessionStatusFilter.unread.color).frame(width: 6, height: 6)
                    .accessibilityLabel(SessionStatusFilter.unread.title)
            }
            Text(title)
                .font(.callout.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isActive || hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Close tab"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: MacSessionTabMetrics.minWidth, maxWidth: MacSessionTabMetrics.maxWidth,
               minHeight: MacSessionTabMetrics.height, maxHeight: MacSessionTabMetrics.height)
        .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.secondary)
        .background(Capsule().fill(fill))
        .opacity(tab.unavailable ? 0.45 : 1)
        .contentShape(Capsule())
        .contentShape(.accessibility, Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.unavailable ? AppLocalization.string("Couldn't open this conversation") : title)
        .contextMenu {
            if let session {
                SessionActionMenuItems(session: session, onRename: { onRename(session) }, onDelete: { onDelete(session) })
            }
            Button(AppLocalization.string("Close Tab"), action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone gives VoiceOver and Voice Control no press action.
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: Text(AppLocalization.string("Close tab")), onClose)
    }

    private var fill: Color {
        if isActive { return .conduitAccent }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }
}

/// Working and needs-input dot; it pulses unless Reduce Motion is on.
private struct MacSessionTabBusyDot: View {
    let filter: SessionStatusFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(filter.color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel(filter.title)
    }
}

/// Fades the strip's ends so a scrolled-off tab reads as more to come
/// (the sidebar filter-chip fade, `macTrailingFade`, fades one edge only).
private struct MacSessionTabEdgeFade: View {
    static let width: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
        }
    }
}
