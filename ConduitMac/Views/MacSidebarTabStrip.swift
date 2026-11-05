import AppKit
import SwiftUI

/// Mac sidebar tab strip (Home | Sessions | Bots | Cron | Kanban | Artifacts, `MacSidebarTabOrder`). A glass container
/// holds equal-width segments; the selected one carries an accent indicator
/// inset uniformly inside the container, with a radius concentric to the
/// container's (`MacTabStripMetrics`). Icon and label are centred in each
/// segment. Replaces upstream's `tabBar` on Mac, where the indicator was the
/// whole cell and its radius was unrelated to the container's.
struct MacSidebarTabStrip: View {
    @Binding var selectedRaw: String

    private var selected: SidebarTab { SidebarTab.migrated(rawValue: selectedRaw) }

    /// Chosen from the strip's own width by `MacTabStripMetrics.ladder` (pure,
    /// so tests pin the steps without hosting): every name; every name except
    /// Home's, which is a compact icon; icons only. With six tabs the second
    /// step needs more than the widest sidebar column gives (D26), so the live
    /// strip shows icons at every column width.
    var body: some View {
        GeometryReader { proxy in
            content(MacTabStripMetrics.ladder(availableWidth: proxy.size.width,
                                              nameSegmentWidths: Self.nameSegmentWidths))
                .frame(width: proxy.size.width, height: MacTabStripMetrics.containerHeight)
                .conduitGlassSurface(cornerRadius: MacTabStripMetrics.containerRadius, tint: .conduitAccent.opacity(0.05))
        }
        .frame(height: MacTabStripMetrics.containerHeight)
    }

    /// Width each tab's icon-and-name segment needs, by tab, measured
    /// with the segment's own font (caption, semibold; small-scale glyph) so
    /// a longer localized name moves the steps.
    static var nameSegmentWidths: [SidebarTab: CGFloat] {
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let glyph = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold, scale: .small)
        return Dictionary(uniqueKeysWithValues: MacSidebarTabOrder.strip.map { tab in
            let text = (tab.displayName as NSString).size(withAttributes: [.font: font]).width
            let icon = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(glyph)?.size.width ?? size
            return (tab, MacTabStripMetrics.nameSegmentWidth(iconWidth: icon.rounded(.up), textWidth: text.rounded(.up)))
        })
    }

    @ViewBuilder
    func content(_ ladder: MacTabStripMetrics.Ladder) -> some View {
        switch ladder {
        case .names:
            EqualWidthHStack(spacing: 0) {
                ForEach(MacSidebarTabOrder.strip, id: \.self) { segment($0, iconOnly: false) }
            }
        case .icons:
            EqualWidthHStack(spacing: 0) {
                ForEach(MacSidebarTabOrder.strip, id: \.self) { segment($0, iconOnly: true) }
            }
        case .homeCompact:
            // Home is found by value: it stays an icon wherever the strip order puts it.
            HStack(spacing: 0) {
                ForEach(Self.compactGroups, id: \.self) { group in
                    if group == [.home] {
                        segment(.home, iconOnly: true)
                            .frame(width: MacTabStripMetrics.homeSegmentWidth)
                    } else {
                        EqualWidthHStack(spacing: 0) {
                            ForEach(group, id: \.self) { segment($0, iconOnly: false) }
                        }
                    }
                }
            }
        }
    }

    /// The strip order split around Home: runs of named tabs and Home on its own, in strip order.
    static var compactGroups: [[SidebarTab]] {
        var groups: [[SidebarTab]] = []
        for tab in MacSidebarTabOrder.strip {
            if tab == .home {
                groups.append([.home])
            } else if let last = groups.last, last != [.home] {
                groups[groups.count - 1].append(tab)
            } else {
                groups.append([tab])
            }
        }
        return groups
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
                    // names at the default 340 pt column (`nameGap`,
                    // `nameMargin`); the strip steps down once they no longer fit.
                    HStack(spacing: MacTabStripMetrics.nameGap) {
                        // The name is on screen, so a tooltip repeating it is
                        // noise. The hint goes on the glyph because a SwiftUI
                        // button takes its identifier from its image.
                        Image(systemName: tab.icon).imageScale(.small).macVisibleLabelHint()
                        Text(tab.displayName).lineLimit(1)
                    }
                    .padding(.horizontal, MacTabStripMetrics.nameMargin)
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
