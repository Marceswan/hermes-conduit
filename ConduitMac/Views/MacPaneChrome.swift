import SwiftUI

/// Header shared by the Mac main-pane views so Bots, Cron and Kanban read the
/// same: Kanban's title treatment (`title3.bold` over a caption subtitle) in a
/// row as tall as Kanban's 32 pt (`MacControlHeight.compact`) action buttons.
/// Kanban's own header is upstream; this matches it.
struct MacPaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: MacControlHeight.compact)
    }
}

extension MacPaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Inline search field styled like Kanban's "Search tasks" bar: a compact
/// (`MacControlHeight.compact`, 32 pt) glass pill, leading magnifier,
/// subheadline text, 10 pt inset, the same radius as the other compact controls.
struct MacSearchPill: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        // The full 24 pt is the hit area, not just the glyph.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, MacSidebarMetrics.searchPillPadding)
        .frame(height: MacControlHeight.compact)
        .conduitGlassControl(cornerRadius: MacSidebarMetrics.controlRadius)
    }
}

/// Trailing fade for horizontally scrolling rows (the sidebar filter chips),
/// so a chip cut at the column edge reads as scrolling, not as a clip bug.
enum MacTrailingFade {
    static let width: CGFloat = 24
}

extension View {
    /// Fades only the trailing edge. The scroll view's own clip is disabled and
    /// the mask extends `verticalOverflow` past the top and bottom, so focus
    /// rings and shadows on the chips are not cut; the mask still bounds the
    /// row horizontally.
    func macTrailingFade(width: CGFloat = MacTrailingFade.width, verticalOverflow: CGFloat = 24) -> some View {
        scrollClipDisabled()
            .mask(
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                }
                .padding(.vertical, -verticalOverflow)
            )
    }
}

extension View {
    /// Draws a fixed-size view (the Workspace profile avatar, 28 pt) at `size`,
    /// and lays it out at `size` too: a scale then a frame, because the
    /// avatar's own frame cannot be overridden from outside.
    func macCompactAvatar(from natural: CGFloat, to size: CGFloat) -> some View {
        scaleEffect(size / natural).frame(width: size, height: size)
    }
}
