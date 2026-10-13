import SwiftUI

/// Header shared by the Mac main-pane views so Bots, Cron and Kanban read the
/// same: Kanban's title treatment (`title3.bold` over a caption subtitle) in a
/// row as tall as Kanban's 36 pt action buttons. Kanban's own header is
/// upstream and unchanged; this matches it.
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
        .frame(minHeight: 36)
    }
}

extension MacPaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Inline search field styled like Kanban's "Search tasks" bar: glass pill,
/// leading magnifier, 40 pt minimum height, 12 pt inset.
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6).frame(minHeight: 40)
        .conduitGlassControl(cornerRadius: 15)
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
