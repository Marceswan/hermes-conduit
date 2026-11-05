import AppKit
import SwiftUI

// The open chat's artifacts beside the chat (D33): a toolbar button that shows once the chat has
// an artifact, and a file tree on the chat's trailing side that the button shows and hides. The
// list is `MacChatArtifactsPanelStore`'s; the tree is `MacArtifactTree`. No upstream counterpart:
// RootView's chat toolbar and chat view each take one gated line.

enum MacChatArtifactsPanelMetrics {
    static let width: CGFloat = 264
    /// Space between the panel and the window edges.
    static let margin: CGFloat = 10
    static let indent: CGFloat = 14
    /// Narrower than this, the panel floats over the chat instead of taking width from it, so the
    /// chat keeps its own minimum (D6).
    static let besideMinWidth: CGFloat = MacSidebarState.detailMinWidth + width + margin

    enum Placement: Equatable {
        case beside
        case over
    }

    static func placement(containerWidth: CGFloat) -> Placement {
        containerWidth >= besideMinWidth ? .beside : .over
    }

    /// The button's number: "+" when the panel read only the first pages.
    static func countText(_ count: Int, truncated: Bool) -> String {
        truncated ? "\(count)+" : "\(count)"
    }
}

/// The chat toolbar's Artifacts button. The toolbar adds it only while `showsButton` is true.
struct MacChatArtifactsToolbarButton: View {
    @ObservedObject private var store: MacChatArtifactsPanelStore

    init(store: MacChatArtifactsPanelStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { store.isOpen }, set: { store.setOpen($0) })) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .semibold))
                if let count = store.count {
                    Text(verbatim: MacChatArtifactsPanelMetrics.countText(count, truncated: store.state.isTruncated))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .toggleStyle(.button)
        .help(store.isOpen ? Text("Hide Artifacts") : Text("Show Artifacts"))
        .accessibilityLabel(Text("Artifacts"))
        .accessibilityValue(Text(verbatim: store.count.map {
            MacChatArtifactsPanelMetrics.countText($0, truncated: store.state.isTruncated)
        } ?? ""))
    }
}

/// The panel: a header (name, count, More, close) over the tree.
struct MacChatArtifactsPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.macArtifactsSource) private var source
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store: MacChatArtifactsPanelStore
    @StateObject private var opener = MacArtifactOpener()
    @AppStorage(ArtifactsClient.showMissingKey) private var showMissing = false
    /// Folders (by host path) and the Links group the user closed.
    @State private var collapsed: Set<String> = []
    /// Show as List, for tests; nil presents the chat's artifacts sheet (D26) from the key window.
    private let showAsList: (([String]) -> Void)?

    init(store: MacChatArtifactsPanelStore? = nil, showAsList: (([String]) -> Void)? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        self.showAsList = showAsList
    }

    /// The chat's artifacts in the sheet's list: kind chips, day sections, pictures as tiles, and
    /// every page past the panel's last one.
    private func presentList() {
        let ids = store.sessionIDs
        if let showAsList {
            showAsList(ids)
        } else {
            MacAppActions.showChatArtifacts(window: NSApp.keyWindow, appState: appState, ids: ids)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
        }
        .macArtifactOpenPresentation(opener)
        .onChange(of: store.key?.dashboard) { _, _ in
            // A download or page read for the old server must not open its file under the new one.
            opener.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Artifacts"))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Artifacts")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let count = store.count {
                Text(verbatim: MacChatArtifactsPanelMetrics.countText(count, truncated: store.state.isTruncated))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if store.state.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 4)
            moreMenu
            Button {
                store.setOpen(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Hide Artifacts"))
            .accessibilityLabel(Text("Hide Artifacts"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Show Missing Files", isOn: $showMissing)
            Divider()
            Button("Refresh") { store.reload() }
            Button("Show as List\u{2026}") { presentList() }
                .disabled(store.sessionIDs.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Tree

    @ViewBuilder
    private var content: some View {
        let items = store.items
        if items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            let rows = MacArtifactTree(items: items).rows(collapsed: collapsed)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if store.state.isTruncated {
                        Button("Show as List\u{2026}") { presentList() }
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.top, 8)
                            .padding(.leading, 8)
                    }
                }
                .padding(6)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MacArtifactTree.Row) -> some View {
        switch row.kind {
        case .folder(let path, let isExpanded):
            groupRow(name: row.name, key: path, symbol: "folder", isExpanded: isExpanded, depth: row.depth, help: path)
        case .links(let isExpanded):
            groupRow(name: row.name, key: MacArtifactTree.linksKey, symbol: "link", isExpanded: isExpanded,
                     depth: row.depth, help: nil)
        case .file(let item), .link(let item):
            itemRow(item, depth: row.depth)
        }
    }

    private func groupRow(name: String, key: String, symbol: String, isExpanded: Bool, depth: Int,
                          help: String?) -> some View {
        MacChatArtifactsPanelRow {
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                if isExpanded { collapsed.insert(key) } else { collapsed.remove(key) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: 16)
                Text(verbatim: name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, CGFloat(depth) * MacChatArtifactsPanelMetrics.indent)
        }
        .help(help.map { Text(verbatim: $0) } ?? Text(verbatim: name))
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }

    private func itemRow(_ item: ArtifactItem, depth: Int) -> some View {
        MacChatArtifactsPanelRow {
            opener.open(item, source: source, appState: appState, openURL: openURL)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: MacArtifactIcon.symbol(for: item.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MacArtifactIcon.tint(for: item.kind))
                    .frame(width: 16)
                Text(verbatim: item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if opener.openingID == item.id {
                    ProgressView().controlSize(.mini)
                }
            }
            // Under its folder's name, past the folder's chevron.
            .padding(.leading, CGFloat(depth) * MacChatArtifactsPanelMetrics.indent + 15)
            .opacity(item.exists ? 1 : 0.5)
        }
        .help(Text(verbatim: item.path ?? item.url?.absoluteString ?? item.name))
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: accessibilityName(item)))
    }

    @ViewBuilder
    private func menu(_ item: ArtifactItem) -> some View {
        Button {
            opener.open(item, source: source, appState: appState, openURL: openURL)
        } label: {
            Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button {
            appState.showArtifactInChat(item, chatIsOpen: true)
        } label: {
            Label("Show in Chat", systemImage: "text.bubble")
        }
        if let url = item.url {
            Button {
                MacArtifactsList.copyLink(url)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        } else if let path = item.path {
            Button {
                MacArtifactsList.copyPath(path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    private func accessibilityName(_ item: ArtifactItem) -> String {
        [item.name, MacArtifactsList.kindLabel(item.kind), item.exists ? "" : AppLocalization.string("No longer on the host")]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// A full-width row button that lights up under the pointer.
private struct MacChatArtifactsPanelRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(isHovered ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MacChatArtifactsPanelLayout: ViewModifier {
    @ObservedObject var store: MacChatArtifactsPanelStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let shows = store.showsPanel
        let placement = MacChatArtifactsPanelMetrics.placement(containerWidth: width)
        content
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if shows, placement == .beside {
                    panel
                }
            }
            .overlay(alignment: .trailing) {
                if shows, placement == .over {
                    panel.shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                }
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: shows)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var panel: some View {
        MacChatArtifactsPanel(store: store)
            .frame(width: MacChatArtifactsPanelMetrics.width)
            .padding(.vertical, MacChatArtifactsPanelMetrics.margin)
            .padding(.trailing, MacChatArtifactsPanelMetrics.margin)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

extension View {
    /// The open chat's artifacts panel on this view's trailing side (D33). Main window chat only.
    func macChatArtifactsPanel(store: MacChatArtifactsPanelStore? = nil) -> some View {
        modifier(MacChatArtifactsPanelLayout(store: store ?? .shared))
    }
}
