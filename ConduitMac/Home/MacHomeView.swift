import SwiftUI

/// The Home pane (D24). Read-only: rows open sessions through `MacHomeActions`,
/// buttons dispatch existing actions. Mounted by `MacDetailRouter` only while it
/// is the shown route, so the model's subscriptions and polls exist only then.
struct MacHomeView: View {
    @StateObject private var model: MacHomeModel
    private let actions: MacHomeActions
    /// The calendar the model buckets days with; weekday names use its time zone.
    private let calendar: Calendar
    /// Test hook: receives the cards' and tiles' frames (`MacHomeFrames`) when they change.
    var frameReport: (([String: CGRect]) -> Void)?

    init(appState: AppState) {
        calendar = .current
        _model = StateObject(wrappedValue: MacHomeBinding.makeModel(appState: appState))
        actions = .live(appState: appState)
    }

    init(model: MacHomeModel, actions: MacHomeActions, calendar: Calendar = .current) {
        _model = StateObject(wrappedValue: model)
        self.actions = actions
        self.calendar = calendar
    }

    var body: some View {
        let snapshot = model.snapshot
        ScrollView {
            ConduitGlassGroup(spacing: MacHomeStyle.sectionGap) {
                VStack(alignment: .leading, spacing: MacHomeStyle.sectionGap) {
                    header(snapshot)
                    if snapshot.connection.state == .offline { offlineNotice }
                    quickActions(snapshot)
                    liveSections(snapshot)
                    tiles(snapshot)
                    modelAndContext(snapshot)
                    recent(snapshot)
                    overview(snapshot)
                }
                .padding(.bottom, 20)
                .coordinateSpace(name: MacHomeFrames.space)
                .onPreferenceChange(MacHomeFrames.self) { frameReport?($0) }
            }
        }
        // Restarts when the dashboard, profile or connection changes.
        .task(id: snapshot.scope) { await model.run() }
    }

    // MARK: Header and actions

    static func subtitle(_ connection: MacHomeConnection) -> String {
        [connection.dashboardLabel, connection.profileName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    private func header(_ snapshot: MacHomeSnapshot) -> some View {
        let subtitle = Self.subtitle(snapshot.connection)
        return MacPaneHeader(title: AppLocalization.string("Home"), subtitle: subtitle.isEmpty ? nil : subtitle) {
            MacHomeConnectionPill(state: snapshot.connection.state)
        }
        .macHomeFrame("header")
    }

    private var offlineNotice: some View {
        Label(AppLocalization.string("Not connected. Showing the last saved list."), systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(MacHomeStyle.secondaryText)
    }

    private func quickActions(_ snapshot: MacHomeSnapshot) -> some View {
        HStack(spacing: MacSidebarMetrics.rowGap) {
            actionButton(AppLocalization.string("New Chat"), "square.and.pencil", enabled: snapshot.canStartChat, actions.newChat)
            actionButton(AppLocalization.string("Quick Ask"), "bolt", enabled: true, actions.quickAsk)
            actionButton(AppLocalization.string("Kanban"), SidebarTab.kanban.icon, enabled: true) { actions.openPane(.kanban) }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: MacControlHeight.compact)
        }
        .conduitGlassControl(cornerRadius: MacSidebarMetrics.controlRadius)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: title))
    }

    // MARK: Live

    @ViewBuilder
    private func liveSections(_ snapshot: MacHomeSnapshot) -> some View {
        if !snapshot.needsYou.isEmpty {
            MacHomeCard(title: AppLocalization.string("Needs you"), symbol: "exclamationmark.bubble") {
                ForEach(snapshot.needsYou) { MacHomeLiveRowView(row: $0, open: actions.openSession) }
            }
        }
        if !snapshot.working.isEmpty {
            MacHomeCard(title: AppLocalization.string("Working"), symbol: "arrow.triangle.2.circlepath") {
                ForEach(snapshot.working) { MacHomeLiveRowView(row: $0, open: actions.openSession) }
            }
        }
        if snapshot.needsYou.isEmpty, snapshot.working.isEmpty, snapshot.feed == .live,
           snapshot.connection.state == .connected {
            Label(AppLocalization.string("Nothing running"), systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(MacHomeStyle.secondaryText)
        }
        if snapshot.feed == .eventsOnly {
            Text(verbatim: AppLocalization.string("Only chats on this connection show here."))
                .font(.caption)
                .foregroundStyle(MacHomeStyle.secondaryText)
        }
    }

    // MARK: Tiles, model, context

    private func tiles(_ snapshot: MacHomeSnapshot) -> some View {
        let t = snapshot.tiles
        // One row of equal tiles across the full content width; 2 x 2 then one column when narrow.
        return MacHomeGrid(columnOptions: MacHomeStyle.tileColumns, minColumnWidth: MacHomeStyle.tileMinWidth, uniformRows: true) {
            MacHomeTile(
                value: "\(t.sessions)", label: AppLocalization.string("Sessions"),
                detail: String(format: AppLocalization.string("Today %@"), String(t.activeToday)),
                // Counts are over the loaded catalog, not the server's total.
                spokenValue: MacHomeText.spoken([
                    String(format: AppLocalization.string("%@ in loaded chats"), String(t.sessions)),
                    String(format: AppLocalization.string("Today %@"), String(t.activeToday)),
                ]), slot: 0)
            MacHomeTile(value: "\(t.unread)", label: AppLocalization.string("Unread"), slot: 1)
            MacHomeTile(
                value: "\(t.needsYou)", label: AppLocalization.string("Waiting on you"),
                detail: t.needsYou == 0 ? nil : String(format: AppLocalization.string("Approvals %1$@, questions %2$@"), String(t.approvals), String(t.questions)), slot: 2)
            MacHomeTile(
                value: "\(t.working)", label: AppLocalization.string("Working"),
                detail: t.subAgents == 0 ? nil : String(format: AppLocalization.string("Sub-agents %@"), String(t.subAgents)), slot: 3)
        }
    }

    @ViewBuilder
    private func modelAndContext(_ snapshot: MacHomeSnapshot) -> some View {
        if snapshot.model != nil || snapshot.context != nil {
            MacHomeGrid(columnOptions: MacHomeStyle.pairColumns, minColumnWidth: MacHomeStyle.wideCardMinWidth) {
                if let line = snapshot.model {
                    MacHomeCard(title: AppLocalization.string("Model"), symbol: "cpu") {
                        Text(verbatim: line.model).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(verbatim: [line.provider, line.effort.isEmpty ? "" : String(format: AppLocalization.string("Reasoning: %@"), line.effort)]
                            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(MacHomeStyle.secondaryText).lineLimit(1)
                    }
                }
                if let context = snapshot.context {
                    MacHomeCard(title: AppLocalization.string("Context"), symbol: "gauge.with.dots.needle.50percent") {
                        MacHomeContextMeter(context: context)
                    }
                }
            }
        }
    }

    // MARK: Recent

    private func recent(_ snapshot: MacHomeSnapshot) -> some View {
        MacHomeCard(title: AppLocalization.string("Recent chats"), symbol: "bubble.left.and.bubble.right") {
            if snapshot.recent.isEmpty {
                Text(verbatim: AppLocalization.string("No chats yet. Start one with New Chat or Quick Ask."))
                    .font(.subheadline).foregroundStyle(MacHomeStyle.secondaryText)
            } else {
                ForEach(snapshot.recent) { MacHomeRecentRowView(row: $0, open: actions.openSession) }
            }
        }
    }

    // MARK: Activity, Kanban, Cron

    private func overview(_ snapshot: MacHomeSnapshot) -> some View {
        let offline = snapshot.connection.state == .offline
        // Equal-width columns across the content width, the same height per row, tops aligned.
        return MacHomeGrid(columnOptions: MacHomeStyle.overviewColumns, minColumnWidth: MacHomeStyle.wideCardMinWidth) {
            MacHomeCard(title: AppLocalization.string("Activity, 7 days"), symbol: "chart.bar") {
                MacHomeDayBars(days: snapshot.days, calendar: calendar)
            }
            kanbanCard(snapshot.kanban, offline: offline)
            cronCard(snapshot.cron, unavailable: snapshot.cronUnavailable, offline: offline)
        }
    }

    private func kanbanCard(_ kanban: MacHomeKanbanSummary, offline: Bool) -> some View {
        MacHomeCard(
            title: AppLocalization.string("Kanban"), symbol: SidebarTab.kanban.icon,
            headerAction: (AppLocalization.string("Open Kanban"), { actions.openPane(.kanban) })
        ) {
            switch kanban.state {
            case .notLoaded:
                note(offline ? AppLocalization.string("Unavailable offline") : AppLocalization.string("Loading"))
            case .unavailable: note(AppLocalization.string("Unavailable"))
            case .empty: note(AppLocalization.string("No tasks"))
            case .loaded:
                cronLine(AppLocalization.string("Total"), kanban.total)
                blockedLine(kanban.blocked)
                MacHomeKanbanBars(bars: kanban.bars)
            }
        }
    }

    private func cronCard(_ cron: MacHomeCronSummary?, unavailable: Bool, offline: Bool) -> some View {
        MacHomeCard(title: AppLocalization.string("Cron"), symbol: SidebarTab.cron.icon) {
            if let cron {
                if cron.active == 0, cron.paused == 0, cron.failing == 0 {
                    note(AppLocalization.string("No scheduled jobs"))
                } else {
                    cronLine(AppLocalization.string("Active"), cron.active)
                    cronLine(AppLocalization.string("Paused"), cron.paused)
                    cronLine(AppLocalization.string("Failing"), cron.failing)
                    if let next = cron.next {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(verbatim: AppLocalization.string("Next run")).font(.caption)
                                Spacer(minLength: 4)
                                // "in 2 hr." with a direction; the timeline keeps it current between snapshots.
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(verbatim: MacHomeText.relative(next.date, now: context.date))
                                        .font(.caption.weight(.semibold)).monospacedDigit()
                                }
                            }
                            Text(verbatim: MacHomeText.untitledJob(next.name)).font(.caption).lineLimit(1)
                                .foregroundStyle(MacHomeStyle.secondaryText)
                        }
                    } else if cron.active > 0 {
                        // Active jobs exist but none has a future run time (overdue or unparseable).
                        note(AppLocalization.string("No upcoming run"))
                    }
                }
            } else if unavailable {
                note(AppLocalization.string("Unavailable"))
            } else {
                note(offline ? AppLocalization.string("Unavailable offline") : AppLocalization.string("Loading"))
            }
        }
    }

    /// Icon and word, so a blocked count is never colour alone.
    private func blockedLine(_ count: Int) -> some View {
        HStack {
            Label {
                Text(verbatim: AppLocalization.string("Blocked")).font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.octagon")
                    .font(.caption)
                    .foregroundStyle(count > 0 ? Color.conduitAccent : MacHomeStyle.secondaryText)
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(count)").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func cronLine(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(verbatim: label).font(.caption)
            Spacer(minLength: 4)
            Text(verbatim: "\(value)").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.subheadline).foregroundStyle(MacHomeStyle.secondaryText)
    }
}
