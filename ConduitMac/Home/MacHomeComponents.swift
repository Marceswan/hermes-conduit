import SwiftUI

// MARK: - Card and tile

/// One glass card with a title row. Rows inside are flat.
struct MacHomeCard<Content: View>: View {
    private let title: String
    private let symbol: String
    private let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(MacHomeStyle.secondaryText)
            }
            content
        }
        .padding(MacHomeStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: MacHomeStyle.cardRadius)
        .accessibilityElement(children: .contain)
    }
}

/// A number over a label, with an optional detail line.
struct MacHomeTile: View {
    let value: String
    let label: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.title2.weight(.bold)).monospacedDigit()
            Text(verbatim: label).font(.subheadline)
            Text(verbatim: detail ?? " ")
                .font(.caption)
                .foregroundStyle(MacHomeStyle.secondaryText)
                .lineLimit(1)
                .opacity(detail == nil ? 0 : 1)
        }
        .padding(MacHomeStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: MacHomeStyle.cardRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: detail.map { "\(value), \($0)" } ?? value))
    }
}

struct MacHomeConnectionPill: View {
    let state: MacHomeConnectionState

    private var label: String {
        switch state {
        case .connected: return AppLocalization.string("Connected")
        case .connecting: return AppLocalization.string("Connecting")
        case .offline: return AppLocalization.string("Offline")
        }
    }

    private var symbol: String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        }
    }

    var body: some View {
        Label { Text(verbatim: label) } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacHomeStyle.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: MacTabStripMetrics.segmentHeight)
            .conduitGlassSurface(cornerRadius: MacSidebarMetrics.controlRadius)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - Rows

enum MacHomeText {
    static func untitled(_ title: String) -> String {
        title.isEmpty ? AppLocalization.string("Untitled chat") : title
    }

    static func untitledJob(_ name: String) -> String {
        name.isEmpty ? AppLocalization.string("Untitled job") : name
    }

    static func kindLabel(_ kind: MacHomeLiveItem.Kind) -> String {
        switch kind {
        case .turn: return AppLocalization.string("Running")
        case .approval: return AppLocalization.string("Approval")
        case .clarify: return AppLocalization.string("Question")
        case .inputPrompt: return AppLocalization.string("Input needed")
        }
    }

    static func kindSymbol(_ kind: MacHomeLiveItem.Kind) -> String {
        switch kind {
        case .turn: return "arrow.triangle.2.circlepath"
        case .approval: return "exclamationmark.shield"
        case .clarify: return "questionmark.bubble"
        case .inputPrompt: return "keyboard"
        }
    }
}

struct MacHomeLiveRowView: View {
    let row: MacHomeLiveRow
    let open: (String) -> Void

    private var accessibilityTitle: String {
        "\(MacHomeText.kindLabel(row.kind)): \(MacHomeText.untitled(row.title))"
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: MacHomeText.kindSymbol(row.kind))
                .frame(width: 18)
                .foregroundStyle(row.needsUser ? Color.conduitAccent : MacHomeStyle.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: MacHomeText.untitled(row.title)).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: MacHomeText.kindLabel(row.kind)).font(.caption.weight(.semibold))
                    if let detail = row.detail {
                        Text(verbatim: detail).font(.caption).lineLimit(1)
                    }
                }
                .foregroundStyle(MacHomeStyle.secondaryText)
            }
            Spacer(minLength: 8)
            Text(row.since, style: .relative)
                .font(.caption).monospacedDigit()
                .foregroundStyle(MacHomeStyle.secondaryText)
        }
        .frame(minHeight: MacHomeStyle.rowHeight)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let id = row.openID {
            Button { open(id) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: accessibilityTitle))
                .accessibilityValue(Text(verbatim: row.detail ?? ""))
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityTitle))
                .accessibilityValue(Text(verbatim: row.detail ?? ""))
        }
    }
}

struct MacHomeRecentRowView: View {
    let row: MacHomeRecentRow
    let open: (String) -> Void

    var body: some View {
        Button { open(row.id) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.conduitAccent)
                    .frame(width: 7, height: 7)
                    .opacity(row.isUnread ? 1 : 0)
                    .frame(width: 18)
                Text(verbatim: MacHomeText.untitled(row.title))
                    .font(.subheadline.weight(row.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !row.model.isEmpty {
                    Text(verbatim: row.model).font(.caption).lineLimit(1)
                        .foregroundStyle(MacHomeStyle.secondaryText)
                }
                if let when = row.lastActivity {
                    Text(when, style: .relative)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(MacHomeStyle.secondaryText)
                        .frame(minWidth: 56, alignment: .trailing)
                        .help(Text(when, format: .dateTime.month().day().hour().minute()))
                }
            }
            .frame(minHeight: MacHomeStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: MacHomeText.untitled(row.title)))
        .accessibilityValue(Text(verbatim: row.isUnread ? AppLocalization.string("Unread") : ""))
    }
}

// MARK: - Charts

/// Sessions touched per day, seven columns, today in the accent hue and the rest neutral
/// (the emphasis form). The accessibility label carries every value, which is also the table view.
struct MacHomeDayBars: View {
    let days: [MacHomeDay]
    var calendar: Calendar = .current

    static func summary(days: [MacHomeDay], calendar: Calendar = .current) -> String {
        days.map { day in
            let name = day.start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated))
            return "\(name) \(day.count)"
        }.joined(separator: ", ")
    }

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 0, 1)
        let plot = MacHomeStyle.chartHeight - 16
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: MacHomeStyle.barGap * 3) {
                ForEach(days) { day in
                    let barHeight: CGFloat = day.count == 0 ? 2 : max(4, plot * CGFloat(day.count) / CGFloat(peak))
                    VStack(spacing: 2) {
                        Text(verbatim: day.isToday ? "\(day.count)" : " ")
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(MacHomeStyle.secondaryText)
                        Spacer(minLength: 0)
                        UnevenRoundedRectangle(
                            topLeadingRadius: MacHomeStyle.topCornerRadius, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: MacHomeStyle.topCornerRadius
                        )
                        .fill(day.isToday ? MacHomeStyle.emphasisMark : MacHomeStyle.mutedMark)
                        .frame(maxWidth: MacHomeStyle.maxBarThickness)
                        .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help(Text(verbatim: "\(day.start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))): \(day.count)"))
                }
            }
            .frame(height: MacHomeStyle.chartHeight)
            HStack(spacing: MacHomeStyle.barGap * 3) {
                ForEach(days) { day in
                    Text(day.start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(MacHomeStyle.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLocalization.string("Sessions per day")))
        .accessibilityValue(Text(verbatim: Self.summary(days: days, calendar: calendar)))
    }
}

/// Horizontal bars, one sequential hue, value at the tip; the label lists every value.
struct MacHomeKanbanBars: View {
    let bars: [MacHomeKanbanBar]

    static func summary(_ bars: [MacHomeKanbanBar]) -> String {
        bars.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bars) { bar in
                HStack(spacing: 8) {
                    Text(verbatim: bar.name).font(.caption).lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MacHomeStyle.track)
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0, bottomLeadingRadius: 0,
                                bottomTrailingRadius: MacHomeStyle.topCornerRadius, topTrailingRadius: MacHomeStyle.topCornerRadius
                            )
                            .fill(MacHomeStyle.emphasisMark)
                            .frame(width: bar.count == 0 ? 0 : max(4, proxy.size.width * bar.fraction))
                        }
                    }
                    .frame(height: 8)
                    Text(verbatim: "\(bar.count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(minWidth: 24, alignment: .trailing)
                }
                .help(Text(verbatim: "\(bar.name): \(bar.count)"))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLocalization.string("Kanban tasks per column")))
        .accessibilityValue(Text(verbatim: Self.summary(bars)))
    }
}

/// One ratio against a limit: a same-ramp track and fill, the number beside it, a warning
/// icon and words (never colour alone) from the high threshold.
struct MacHomeContextMeter: View {
    let context: MacHomeContext

    static func tokens(_ context: MacHomeContext) -> String {
        guard context.max > 0 else { return "" }
        let used = context.used.formatted(.number.notation(.compactName))
        let limit = context.max.formatted(.number.notation(.compactName))
        return String(format: AppLocalization.string("%@ of %@ tokens"), used, limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MacHomeStyle.track)
                        Capsule().fill(MacHomeStyle.emphasisMark)
                            .frame(width: max(MacHomeStyle.meterHeight, proxy.size.width * context.percent / 100))
                    }
                }
                .frame(height: MacHomeStyle.meterHeight)
                Text(verbatim: "\(Int(context.percent.rounded()))%")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            let tokens = Self.tokens(context)
            if !tokens.isEmpty {
                Text(verbatim: tokens).font(.caption).foregroundStyle(MacHomeStyle.secondaryText)
            }
            if context.isHigh {
                Label(AppLocalization.string("Context is nearly full"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLocalization.string("Context")))
        .accessibilityValue(Text(verbatim: "\(Int(context.percent.rounded())) %, \(Self.tokens(context))"))
    }
}
