import SwiftUI

enum MacSessionTabMetrics {
    static let height: CGFloat = 28
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 220
}

/// The chat toolbar's session tabs (D11), in place of the title pill. The
/// system toolbar platter is the only glass layer (D7): tabs are flat pills.
struct MacSessionTabStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MacSessionTabsStore
    @ObservedObject private var windows = MacSessionWindowRegistry.shared
    @Environment(\.openWindow) private var openWindow
    /// The toolbar room around the strip; the principal slot sizes the item to its ideal width.
    @State private var slotWidth: CGFloat = MacSessionTabMetrics.minWidth
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
                            onDelete: onDelete,
                            onPopOut: { popOut(tab.id) },
                            canPopOut: Self.popOutEnabled(tab: tab, catalog: appState.sessions, windowsFull: windows.isFull)
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, MacSessionTabEdgeFade.width)
            }
            .mask(MacSessionTabEdgeFade())
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: store.model.activeID) { _, _ in scroll(proxy, animated: true) }
            // A narrower strip must not leave the active tab off its edge.
            .onChange(of: slotWidth) { _, _ in scroll(proxy, animated: false) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in scroll(proxy, animated: false) }
        }
        .frame(minWidth: MacSessionTabMetrics.minWidth,
               idealWidth: max(MacSessionTabMetrics.minWidth, slotWidth), maxWidth: .infinity)
        .frame(height: MacSessionTabMetrics.height)
        .background(MacToolbarSlotReader { slotWidth = $0 })
    }

    /// The context menu's "Open in New Window". A Bot Chat (or any session the workspace catalog does
    /// not list) cannot resume in a window, an unavailable tab has nothing to open, and the cap is 4.
    static func popOutEnabled(tab: MacSessionTab, catalog: [SessionSummary], windowsFull: Bool) -> Bool {
        !windowsFull && !tab.unavailable && MacSessionWindows.canPopOut(tab.id, catalog: catalog)
    }

    private func popOut(_ id: String) {
        store.popOut(id) { sessionID in
            MacSessionWindows.open(sessionID, appState: appState) { openWindow(value: $0) }
        }
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
    let onPopOut: () -> Void
    let canPopOut: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var title: String { session?.title ?? tab.title }
    private var showsClose: Bool { isActive || hovering }

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
            // Always laid out: showing it on hover must not change the tab's width.
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .accessibilityHidden(!showsClose)
            .accessibilityLabel(AppLocalization.string("Close Tab"))
        }
        .padding(.horizontal, 10)
        .frame(minWidth: MacSessionTabMetrics.minWidth, maxWidth: MacSessionTabMetrics.maxWidth,
               minHeight: MacSessionTabMetrics.height, maxHeight: MacSessionTabMetrics.height)
        .foregroundStyle(isActive ? Self.activeText(colorScheme) : Color.secondary)
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
            Button(AppLocalization.string("Open in New Window"), action: onPopOut)
                .disabled(!canPopOut)
            Button(AppLocalization.string("Close Tab"), action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // A tap gesture alone gives VoiceOver and Voice Control no press action.
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: Text(AppLocalization.string("Close Tab")), onClose)
    }

    /// On the accent fill: dark text on the light amber, white on the dark brown
    /// (black at 85% on the light-mode brown is 3.4:1; white is 5.6:1).
    static func activeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.85) : Color.white
    }

    private var fill: Color {
        if isActive { return .conduitAccent }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }
}

/// Working and needs-input dot; it pulses unless Reduce Motion is on. The
/// repeat is scoped to the opacity: started with `withAnimation`, it also took
/// the toolbar's layout change in the same update, and the whole tab row swung
/// up and left and back with every pulse.
private struct MacSessionTabBusyDot: View {
    let filter: SessionStatusFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(filter.color)
            .frame(width: 6, height: 6)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { $0.opacity(dim ? 0.35 : 1) }
            .onAppear { dim = !reduceMotion }
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
