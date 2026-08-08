//
//  KanbanTaskDetailSheet.swift
//  Conduit
//

import SwiftUI

struct KanbanTaskDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: KanbanBoardService
    let taskID: String

    @State private var detail: KanbanTaskDetail?
    @State private var loadError: String?
    @State private var log: KanbanTaskLog?
    @State private var logLoading = false
    @State private var showBlockPrompt = false
    @State private var blockReason = ""
    @State private var showDeleteConfirm = false
    @State private var showReclaimConfirm = false
    @State private var commentDraft = ""
    @State private var isSendingComment = false

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let detail {
                            content(detail)
                        } else if let loadError {
                            ContentUnavailableView(
                                "Couldn't Load Task",
                                systemImage: "exclamationmark.triangle",
                                description: Text(loadError)
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            ProgressView("Loading task…")
                                .tint(.conduitAccent)
                                .frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: detail?.task.title ?? "Task", close: { dismiss() })
            }
        }
        .presentationDetents([.large])
        .task(id: taskID) {
            do {
                detail = try await service.loadTaskDetail(taskID)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
        .alert("Block task?", isPresented: $showBlockPrompt) {
            TextField("Reason (optional)", text: $blockReason)
            Button("Block") {
                let reason = blockReason
                blockReason = ""
                Task {
                    await service.moveTask(taskID, to: KanbanStatus.blocked.rawValue, blockReason: reason)
                    await refetchDetail()
                }
            }
            Button("Cancel", role: .cancel) { blockReason = "" }
        } message: {
            Text("The dispatcher skips blocked tasks until they are unblocked.")
        }
        .alert("Delete task?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    if await service.deleteTask(taskID) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the task and cannot be undone.")
        }
        .alert("Reclaim run?", isPresented: $showReclaimConfirm) {
            Button("Reclaim") {
                Task {
                    await service.reclaimTask(taskID)
                    await refetchDetail()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops the running worker and returns the task to Ready.")
        }
    }

    private func refetchDetail() async {
        if let refreshed = try? await service.loadTaskDetail(taskID) {
            detail = refreshed
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ detail: KanbanTaskDetail) -> some View {
        if let error = service.lastActionError {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(error.id)
        }

        overviewSection(detail)

        if let body = detail.body, !body.isEmpty {
            ConduitSettingsSection(title: "Description", symbol: "text.quote", tint: .conduitAura) {
                MarkdownText(source: body)
            }
        }

        if let result = detail.result, !result.isEmpty {
            ConduitSettingsSection(title: "Result", symbol: "checkmark.seal", tint: .green) {
                MarkdownText(source: result)
            }
        }

        if detail.task.kanbanStatus == .blocked {
            blockedSection(detail.task)
        }

        if !detail.task.diagnostics.isEmpty {
            diagnosticsSection(detail.task.diagnostics)
        }

        if detail.task.progress != nil || !detail.childResults.isEmpty {
            subtasksSection(detail)
        }

        commentsSection(detail.comments)

        if !detail.runs.isEmpty {
            runsSection(detail.runs)
        }

        if !detail.events.isEmpty {
            eventsSection(detail.events)
        }

        logSection

        Button {
            Haptics.warning()
            showDeleteConfirm = true
        } label: {
            Label("Delete task", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        }
        .disabled(service.mutatingTaskID != nil)
        .conduitGlassControl(cornerRadius: 16, tint: .red.opacity(0.12))
    }

    private func overviewSection(_ detail: KanbanTaskDetail) -> some View {
        let task = detail.task
        let status = task.kanbanStatus
        let isRunning = status == .running
        let mutationInFlight = service.mutatingTaskID != nil
        return ConduitSettingsSection(title: "Overview", symbol: "info.circle", tint: .conduitAccent) {
            if isRunning {
                SettingsMetricRow(
                    label: "Status",
                    value: status?.displayName ?? task.status.capitalized,
                    statusDot: status?.tint ?? .secondary
                )
                Text("Status is managed by the dispatcher while running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Haptics.warning()
                    showReclaimConfirm = true
                } label: {
                    Label("Reclaim run", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .disabled(mutationInFlight)
                .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.14))
            } else {
                ConduitMenuPicker(
                    value: task.status,
                    choices: statusChoices(for: task),
                    onSelect: { selected in
                        guard selected != task.status else { return }
                        Haptics.selection()
                        if selected == KanbanStatus.blocked.rawValue {
                            showBlockPrompt = true
                        } else {
                            Task {
                                await service.moveTask(taskID, to: selected)
                                await refetchDetail()
                            }
                        }
                    },
                    label: { Text("Status").foregroundStyle(.secondary) }
                )
                .disabled(mutationInFlight)
            }
            ConduitMenuPicker(
                value: task.assignee ?? "",
                choices: assigneeChoices(for: task),
                onSelect: { selected in
                    guard selected != (task.assignee ?? "") else { return }
                    Haptics.selection()
                    Task {
                        await service.reassignTask(taskID, to: selected.isEmpty ? nil : selected)
                        await refetchDetail()
                    }
                },
                label: { Text("Assignee").foregroundStyle(.secondary) }
            )
            .disabled(isRunning || mutationInFlight)
            HStack(spacing: 10) {
                Text("Priority")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button {
                    Haptics.selection()
                    Task {
                        await service.setPriority(taskID, to: task.priority - 1)
                        await refetchDetail()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled(mutationInFlight)
                Text("\(task.priority)")
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: 28)
                Button {
                    Haptics.selection()
                    Task {
                        await service.setPriority(taskID, to: task.priority + 1)
                        await refetchDetail()
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .disabled(mutationInFlight)
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            if let tenant = task.tenant {
                SettingsMetricRow(label: "Tenant", value: tenant)
            }
            if let branch = task.branchName {
                SettingsMetricRow(label: "Branch", value: branch, lineLimit: 1)
            }
            if let workspace = task.workspaceKind {
                SettingsMetricRow(label: "Workspace", value: workspace.capitalized)
            }
            if let model = task.modelOverride {
                SettingsMetricRow(label: "Model", value: task.providerOverride.map { "\(model) (\($0))" } ?? model, lineLimit: 1)
            }
            if let effort = task.reasoningEffort {
                SettingsMetricRow(label: "Reasoning", value: effort.capitalized)
            }
            if task.goalMode == true {
                SettingsMetricRow(label: "Mode", value: "Goal")
            }
            if !task.skills.isEmpty {
                SettingsMetricRow(label: "Skills", value: task.skills.joined(separator: ", "), lineLimit: 2)
            }
            if let created = KanbanNormalizer.ageLabel(task.age.createdAgeSeconds) {
                SettingsMetricRow(label: "Created", value: "\(created) ago")
            }
            if let started = KanbanNormalizer.ageLabel(task.age.startedAgeSeconds) {
                SettingsMetricRow(label: "Started", value: "\(started) ago")
            }
            if let duration = KanbanNormalizer.ageLabel(task.age.timeToCompleteSeconds) {
                SettingsMetricRow(label: "Completed in", value: duration)
            }
            if detail.parents.count + detail.children.count > 0 {
                SettingsMetricRow(label: "Links", value: "\(detail.parents.count) parents · \(detail.children.count) children")
            }
            if let sessionID = task.sessionID {
                openSessionButton(sessionID, label: "Open originating session")
            }
        }
    }

    private func blockedSection(_ task: KanbanTaskCard) -> some View {
        ConduitSettingsSection(title: "Blocked", symbol: "hand.raised.fill", tint: .orange) {
            if let kind = task.blockKind {
                SettingsMetricRow(label: "Kind", value: kind.capitalized)
            }
            if let reason = task.blockReason {
                Text(reason)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if task.consecutiveFailures > 0 {
                SettingsMetricRow(
                    label: "Consecutive failures",
                    value: "\(task.consecutiveFailures)",
                    valueColor: .orange
                )
            }
        }
    }

    private func diagnosticsSection(_ diagnostics: [KanbanDiagnostic]) -> some View {
        ConduitSettingsSection(title: "Diagnostics", symbol: "stethoscope", tint: .orange) {
            ForEach(diagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(diagnostic.severity == "critical" || diagnostic.severity == "error" ? Color.red : .orange)
                            .frame(width: 7, height: 7)
                        Text(diagnostic.title)
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        if let count = diagnostic.count, count > 1 {
                            Text("×\(count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detailText = diagnostic.detail, detailText != diagnostic.title {
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func subtasksSection(_ detail: KanbanTaskDetail) -> some View {
        ConduitSettingsSection(title: "Subtasks", symbol: "checklist", tint: .conduitAura) {
            if let progress = detail.task.progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.conduitAccent)
            }
            ForEach(detail.childResults) { child in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(KanbanStatus.from(child.status)?.tint ?? .secondary)
                            .frame(width: 7, height: 7)
                        Text(child.title)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    if let summary = child.latestSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func commentsSection(_ comments: [KanbanComment]) -> some View {
        ConduitSettingsSection(title: "Comments", symbol: "bubble.left.and.bubble.right", tint: .conduitAura) {
            if comments.isEmpty {
                Text("No comments yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(comment.author ?? "unknown")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        if let time = relativeTime(comment.createdAt) {
                            Text(time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(comment.body)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment…", text: $commentDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { sendComment() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .conduitGlassSurface(cornerRadius: 14)
                Button {
                    sendComment()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.conduitAccent.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(trimmedCommentDraft.isEmpty || isSendingComment)
                .opacity(trimmedCommentDraft.isEmpty || isSendingComment ? 0.45 : 1)
                .accessibilityLabel("Send comment")
            }
        }
    }

    private var trimmedCommentDraft: String {
        commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendComment() {
        let body = trimmedCommentDraft
        guard !body.isEmpty, !isSendingComment else { return }
        Haptics.selection()
        Task {
            isSendingComment = true
            defer { isSendingComment = false }
            if await service.addComment(taskID, body: body) {
                commentDraft = ""
                Haptics.success()
                await refetchDetail()
            } else {
                Haptics.error()
            }
        }
    }

    private func statusChoices(for task: KanbanTaskCard) -> [(id: String, title: String)] {
        let current = (
            id: task.status,
            title: task.kanbanStatus?.displayName ?? task.status.capitalized
        )
        let targets = KanbanStatus.moveTargets(excluding: task.status).map { (id: $0.rawValue, title: $0.displayName) }
        return [current] + targets
    }

    private func assigneeChoices(for task: KanbanTaskCard) -> [(id: String, title: String)] {
        var names = service.assigneeOptions.isEmpty ? (service.snapshot?.assignees ?? []) : service.assigneeOptions
        if let current = task.assignee, !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return [(id: "", title: "Unassigned")] + names.map { (id: $0, title: $0) }
    }

    private func runsSection(_ runs: [KanbanRun]) -> some View {
        ConduitSettingsSection(title: "Runs", symbol: "play.circle", tint: .conduitAccent) {
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(runTint(run))
                            .frame(width: 7, height: 7)
                        Text(run.profile ?? "worker")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Text(run.outcome ?? run.status ?? "—")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let summary = run.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if let error = run.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func eventsSection(_ events: [KanbanEvent]) -> some View {
        ConduitSettingsSection(title: "Recent events", symbol: "clock.arrow.circlepath", tint: .conduitAura) {
            ForEach(events.suffix(20).reversed()) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.kind)
                        .font(.caption.weight(.semibold))
                    if let summary = event.payloadSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let time = relativeTime(event.createdAt) {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var logSection: some View {
        ConduitSettingsSection(title: "Worker log", symbol: "terminal", tint: .conduitAura) {
            if let log {
                if log.exists {
                    ScrollView {
                        Text(log.content.isEmpty ? "Log is empty." : log.content)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    if log.truncated {
                        Text("Showing the last \(log.content.count) characters of \(log.sizeBytes) bytes.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No log for this task yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Haptics.selection()
                    Task {
                        logLoading = true
                        defer { logLoading = false }
                        log = try? await service.loadTaskLog(taskID)
                        if log == nil {
                            log = KanbanTaskLog(exists: false, sizeBytes: 0, content: "", truncated: false)
                        }
                    }
                } label: {
                    Label(logLoading ? "Loading…" : "Load log tail", systemImage: "arrow.down.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .disabled(logLoading)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
            }
        }
    }

    // MARK: Helpers

    private func openSessionButton(_ sessionID: String, label: String) -> some View {
        Button {
            Haptics.selection()
            appState.showSidebar = false
            dismiss()
            Task { await appState.openSession(sessionID) }
        } label: {
            Label(label, systemImage: "bubble.left.and.text.bubble.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
    }

    private func runTint(_ run: KanbanRun) -> Color {
        switch run.outcome ?? run.status ?? "" {
        case "completed", "done": return .green
        case "running": return .conduitAccent
        case "blocked": return .orange
        case "crashed", "timed_out", "failed", "spawn_failed", "gave_up": return .red
        default: return .secondary
        }
    }

    private func relativeTime(_ unixSeconds: Double?) -> String? {
        guard let unixSeconds, unixSeconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: unixSeconds)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
