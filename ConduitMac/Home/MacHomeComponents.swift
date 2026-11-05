import SwiftUI

// MARK: - Card and tile

/// Frames of the cards and tiles in the Home content's coordinate space, by name. Read by the
/// layout tests (`MacHomeView.frameReport`); nothing in the app uses them. Accessibility frames
/// cannot serve: SwiftUI reports a container's content, not its glass.
struct MacHomeFrames: PreferenceKey {
    static let space = "macHomeContent"
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func macHomeFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MacHomeFrames.self, value: [name: proxy.frame(in: .named(MacHomeFrames.space))])
        })
    }
}

/// One glass card with a title row. Rows inside are flat.
struct MacHomeCard<Content: View>: View {
    private let title: String
    private let symbol: String
    private let headerAction: (label: String, run: () -> Void)?
    private let content: Content

    /// `headerAction` turns the title row into a button (the Kanban card opens its pane).
    init(
        title: String, symbol: String,
        headerAction: (label: String, run: () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.headerAction = headerAction
        self.content = content()
    }

    @ViewBuilder
    private var header: some View {
        let titleRow = Label {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: symbol).foregroundStyle(MacHomeStyle.secondaryText)
        }
        if let headerAction {
            Button(action: headerAction.run) {
                HStack(spacing: 4) {
                    titleRow
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MacHomeStyle.secondaryText)
                }
                .frame(minHeight: MacHomeStyle.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: headerAction.label))
            .accessibilityAddTraits(.isHeader)
        } else {
            // Same height as the button form, so cards side by side start their content level.
            titleRow
                .frame(minHeight: MacHomeStyle.headerHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(MacHomeStyle.cardPadding)
        // Fills the cell the grid gives it (equal row heights) and keeps its content at the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .conduitGlassSurface(cornerRadius: MacHomeStyle.cardRadius)
        .accessibilityElement(children: .contain)
        .macHomeFrame("card.\(symbol)")
    }
}

/// A number over a label, with an optional detail line.
struct MacHomeTile: View {
    let value: String
    let label: String
    var detail: String?
    /// Replaces "value, detail" for VoiceOver (the Sessions tile says what it counts).
    var spokenValue: String?
    /// Names the tile in `MacHomeFrames` (layout tests); not spoken.
    var slot = 0

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .conduitGlassSurface(cornerRadius: MacHomeStyle.cardRadius)
        .macHomeFrame("tile.\(slot)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: spokenValue ?? detail.map { "\(value), \($0)" } ?? value))
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

    /// "4 min. ago" / "in 2 hr." against an explicit `now`, so it is testable and a timeline can drive it.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func spoken(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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

    /// What a screen reader adds after the label: the command or tool, and how long ago it started.
    var spokenValue: String {
        MacHomeText.spoken([row.detail, MacHomeText.relative(row.since)])
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
                .accessibilityValue(Text(verbatim: spokenValue))
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityTitle))
                .accessibilityValue(Text(verbatim: spokenValue))
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
        .accessibilityValue(Text(verbatim: spokenValue))
    }

    /// Unread state, model and how long ago, as the row shows them.
    var spokenValue: String {
        MacHomeText.spoken([
            row.isUnread ? AppLocalization.string("Unread") : nil,
            row.model,
            row.lastActivity.map { MacHomeText.relative($0) },
        ])
    }
}

// MARK: - Charts

/// Sessions touched per day, seven columns, today in the accent hue and the rest neutral
/// (the emphasis form). The accessibility value carries every number, which is also the table view.
struct MacHomeDayBars: View {
    private struct Column: Identifiable {
        var day: MacHomeDay
        var abbreviated: String
        var wide: String
        var narrow: String
        var id: Date { day.id }
    }

    private let columns: [Column]
    private let summaryText: String

    /// Weekday names are formatted once per `days` value, not on every body evaluation.
    init(days: [MacHomeDay], calendar: Calendar = .current) {
        func name(_ date: Date, _ width: Date.FormatStyle.Symbol.Weekday) -> String {
            date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(width))
        }
        columns = days.map {
            Column(day: $0, abbreviated: name($0.start, .abbreviated), wide: name($0.start, .wide), narrow: name($0.start, .narrow))
        }
        summaryText = Self.summary(days: days, calendar: calendar)
    }

    static func summary(days: [MacHomeDay], calendar: Calendar = .current) -> String {
        days.map { day in
            let name = day.start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated))
            return "\(name) \(day.count)"
        }.joined(separator: ", ")
    }

    var body: some View {
        let peak = max(columns.map(\.day.count).max() ?? 0, 1)
        VStack(spacing: 4) {
            // The plot takes whatever height the card gives it (never less than `chartHeight`),
            // so a card stretched to its row's height gets a taller chart, not empty space.
            GeometryReader { proxy in
                // Each column stacks caption, spacer and bar with a gap between each pair, so the
                // tallest bar is the plot height minus the caption and two gaps: no overflow.
                let plot = max(8, proxy.size.height - MacHomeStyle.dayValueHeight - 2 * MacHomeStyle.dayValueGap)
                HStack(alignment: .bottom, spacing: MacHomeStyle.barGap * 3) {
                    ForEach(columns) { column in
                        let day = column.day
                        let barHeight: CGFloat = day.count == 0 ? 2 : max(4, plot * CGFloat(day.count) / CGFloat(peak))
                        VStack(spacing: MacHomeStyle.dayValueGap) {
                            Text(verbatim: day.isToday ? "\(day.count)" : " ")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(MacHomeStyle.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(height: MacHomeStyle.dayValueHeight)
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
                        .help(Text(verbatim: "\(column.wide): \(day.count)"))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(minHeight: MacHomeStyle.chartHeight, maxHeight: .infinity)
            HStack(spacing: MacHomeStyle.barGap * 3) {
                ForEach(columns) { column in
                    Text(verbatim: column.narrow)
                        .font(.caption2)
                        .foregroundStyle(MacHomeStyle.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLocalization.string("Sessions per day")))
        .accessibilityValue(Text(verbatim: summaryText))
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

    /// The spoken value: percent, tokens when the limit is known, and the warning when high.
    static func spokenValue(_ context: MacHomeContext) -> String {
        MacHomeText.spoken([
            "\(Int(context.percent.rounded())) %",
            tokens(context),
            context.isHigh ? AppLocalization.string("Context is nearly full") : nil,
        ])
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
        .accessibilityValue(Text(verbatim: Self.spokenValue(context)))
    }
}
