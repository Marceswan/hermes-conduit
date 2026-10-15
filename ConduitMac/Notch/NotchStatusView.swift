import SwiftUI

/// Everything the gateway or the agent wrote (row titles, tool names, commands, error
/// text) reaches this file already sanitized by `MacUntrustedText` and is drawn with
/// `Text(verbatim:)`, so no Markdown, link or localization lookup applies to it.
struct NotchStatusView: View {
    @ObservedObject var model: NotchStatusViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.surface {
            case .hidden: Color.clear
            case .compact: compact
            case .expanded: expanded
            }
        }
        .foregroundStyle(NotchPalette.text)
        .environment(\.colorScheme, .dark)
        .animation(NotchMotion.animation(reduceMotion: reduceMotion), value: model.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilitySummary)
    }

    // MARK: compact

    @ViewBuilder private var compact: some View {
        Group {
            switch (model.layout.style, model.layout.compactAxis) {
            case (.wings, _): wingsCompact
            case (.pill, .horizontal): pillCompact(vertical: false)
            case (.pill, .vertical): pillCompact(vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.onResetPosition() }   // double-click the capsule: back to the default
    }

    private func pillCompact(vertical: Bool) -> some View {
        let attention = model.list.counts.needsUser > 0
        return Group {
            if vertical {
                VStack(spacing: 6) {
                    mark.frame(width: NotchMetrics.pillHeight)
                    if let short = model.compactLabel.shortCount {
                        Text(verbatim: short).font(.caption.weight(.semibold)).foregroundStyle(attention ? NotchPalette.attention : NotchPalette.text)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    mark.frame(width: 24)
                    compactText.lineLimit(1)
                }.padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchPalette.surface, in: shape)
    }

    private var wingsCompact: some View {
        HStack(spacing: 0) {
            mark.frame(width: NotchMetrics.leftWing)
            if model.placement.notchWidth > 0 { Spacer(minLength: model.placement.notchWidth) }
            compactText.frame(maxWidth: .infinity, alignment: model.placement.notchWidth > 0 ? .leading : .center).padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchPalette.surface, in: shape)
    }

    private var mark: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "sparkle")
                .symbolEffect(.pulse, isActive: model.list.counts.working > 0 && !reduceMotion)
            if model.list.counts.needsUser > 0 {
                Circle().fill(NotchPalette.attention).frame(width: 7, height: 7).offset(x: 3, y: -2)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var compactText: some View {
        switch model.compactLabel {
        case .needYou(let n): Text("\(n) need you").foregroundStyle(NotchPalette.attention)
        case .tool(let name): Text(verbatim: name).lineLimit(1)
        case .working(let n): Text("\(n) working")
        case .done: Text("Done")
        case .none: EmptyView()
        }
    }

    // MARK: expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.reservedTopHeight > 0 { Color.clear.frame(height: model.reservedTopHeight) }   // beside the notch the wings stay empty
            if model.layout.isDocked && !model.layout.gripAtBottom { grip }
            if model.list.rows.isEmpty { emptyState } else { rows }
            if model.list.overflow > 0 {
                Button { model.onOpenMore() } label: { Text("+\(model.list.overflow) more") }
                    .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 6)
                    .foregroundStyle(NotchPalette.secondary)
            }
            Divider().overlay(NotchPalette.secondary.opacity(0.3))
            footer
            if model.layout.isDocked && model.layout.gripAtBottom { grip }
        }
        .padding(.bottom, 8)
        .frame(width: NotchMetrics.expandedWidth, alignment: .top)
        .background(NotchPalette.surface, in: shape)
        .background(GeometryReader { g in Color.clear.preference(key: NotchHeightKey.self, value: g.size.height) })
        .onPreferenceChange(NotchHeightKey.self) { model.contentHeight = $0 }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.list.rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 || model.list.rows[index - 1].section != row.section {
                    sectionHeader(row.section)
                }
                NotchStatusRowView(row: row, model: model)
            }
        }
    }

    private func sectionHeader(_ s: NotchRow.Section) -> some View {
        Group {
            switch s {
            case .needsYou: Text("Needs you")
            case .working: Text("Working")
            case .done: Text("Done")
            }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(NotchPalette.secondary)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.emptyState {
            case .disconnected:
                Text("Not connected to Hermes").font(.callout.weight(.semibold))
            case .noAgents:
                Text("No agents running").font(.callout.weight(.semibold))
                Text("Chats started from the CLI, Slack or another app are not shown here.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
            }
            if model.showsEventsOnlyNote {
                Text("Only chats opened in Conduit are tracked right now.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cron = model.list.cron {
                Button { model.onOpenCron() } label: {
                    Text(verbatim: AppLocalization.string("Next cron: \(cron.title), \(NotchRelativeTime.string(for: cron.at))"))
                        .font(.caption).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }.buttonStyle(.plain)
            }
            HStack {
                Button { model.onNewChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(!model.newChatEnabled)
                Spacer()
                Button { model.onOpenConduit() } label: { Text("Open Conduit") }
            }
            .buttonStyle(.plain).font(.callout)
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    /// The visible drag handle next to the docked edge. The whole panel drags (the base keeps
    /// sub-threshold presses as clicks); the grip only signals it and takes the double-click.
    private var grip: some View {
        Capsule().fill(NotchPalette.secondary.opacity(0.5))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity).frame(height: 14)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.onResetPosition() }
            .accessibilityElement()
            .accessibilityLabel(AppLocalization.string("Agent status position handle"))
            .accessibilityHint(AppLocalization.string("Drag to move. Double-click to return to the notch."))
    }

    /// Rounded corners face inward, away from the screen edge.
    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = 14
        switch model.layout.inwardSide {
        case .bottom: return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous)
        case .top: return UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r, style: .continuous)
        case .trailing: return UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .leading: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous)
        }
    }
}

private struct NotchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum NotchRelativeTime {
    static func string(for date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLocalization.formattingLocale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
