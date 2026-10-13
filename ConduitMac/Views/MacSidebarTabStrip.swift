import SwiftUI

/// Mac sidebar tab strip (Sessions | Bots | Cron | Kanban). A glass container
/// holds equal-width segments; the selected one carries an accent indicator
/// inset uniformly inside the container, with a radius concentric to the
/// container's (`MacTabStripMetrics`). Icon and label are centred in each
/// segment. Replaces upstream's `tabBar` on Mac, where the indicator was the
/// whole cell and its radius was unrelated to the container's.
struct MacSidebarTabStrip: View {
    @Binding var selectedRaw: String

    private var selected: SidebarTab { SidebarTab.migrated(rawValue: selectedRaw) }

    var body: some View {
        // Every tab drops to its icon together once the names no longer fit
        // their segments (large text), as upstream does.
        ViewThatFits(in: .horizontal) {
            strip(iconOnly: false)
            strip(iconOnly: true)
        }
    }

    private func strip(iconOnly: Bool) -> some View {
        EqualWidthHStack(spacing: 0) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                segment(tab, iconOnly: iconOnly)
            }
        }
        .frame(height: MacTabStripMetrics.containerHeight)
        .conduitGlassSurface(cornerRadius: MacTabStripMetrics.containerRadius, tint: .conduitAccent.opacity(0.05))
    }

    private func segment(_ tab: SidebarTab, iconOnly: Bool) -> some View {
        let isSelected = selected == tab
        let indicator = RoundedRectangle(cornerRadius: MacTabStripMetrics.indicatorRadius, style: .continuous)
        return Button {
            withAnimation(ConduitMotion.response) {
                Haptics.selection()
                selectedRaw = tab.rawValue
            }
        } label: {
            Group {
                if iconOnly {
                    Label(tab.displayName, systemImage: tab.icon)
                        .labelStyle(.iconOnly)
                        .conduitFixedGlyph()
                } else {
                    // A tight icon-to-name gap and a 3 pt side margin keep the
                    // names at the default 340 pt column; the strip falls back
                    // to icons only once they no longer fit.
                    HStack(spacing: 4) {
                        // The name is on screen, so a tooltip repeating it is
                        // noise. The hint goes on the glyph because a SwiftUI
                        // button takes its identifier from its image.
                        Image(systemName: tab.icon).imageScale(.small).macVisibleLabelHint()
                        Text(tab.displayName).lineLimit(1)
                    }
                    .padding(.horizontal, 3)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: MacTabStripMetrics.segmentHeight,
                   maxHeight: MacTabStripMetrics.segmentHeight)
            .background(isSelected ? Color.conduitAccent.opacity(0.16) : .clear, in: indicator)
            // Also what the accessibility layer reports as the control's shape,
            // so the hover outline follows the indicator, not the whole cell.
            .contentShape(indicator)
        }
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer {
            Label(tab.displayName, systemImage: tab.icon)
        }
        .accessibilityLabel(tab.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // The inset sits outside the button, so its frame is the indicator.
        .padding(MacTabStripMetrics.inset)
    }
}
