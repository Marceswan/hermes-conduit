//
//  KanbanBoardView.swift
//  Conduit
//

import SwiftUI

extension KanbanStatus {
    var tint: Color {
        switch self {
        case .triage: return .secondary
        case .todo: return .secondary
        case .scheduled: return .cyan
        case .ready: return .conduitAura
        case .running: return .conduitAccent
        case .blocked: return .orange
        case .review: return .purple
        case .done: return .green
        case .archived: return .secondary
        }
    }
}

/// Sidebar tab entry point. Owns bridge-nil handling; the route below owns the
/// service lifetime, rebuilt per server via `.id(bridge.baseURL)`.
struct KanbanBoardTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let bridge = appState.dashboardTicketBridge {
            KanbanBoardRoute(bridge: bridge)
                .id(bridge.baseURL)
        } else {
            ContentUnavailableView(
                "Dashboard Required",
                systemImage: "rectangle.split.3x1",
                description: Text("Connect to a Hermes dashboard to see its board.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct KanbanBoardRoute: View {
    @StateObject private var service: KanbanBoardService

    init(bridge: DashboardTicketBridge) {
        _service = StateObject(wrappedValue: KanbanBoardService(bridge: bridge))
    }

    var body: some View {
        KanbanBoardView(service: service)
    }
}

struct KanbanBoardView: View {
    @ObservedObject var service: KanbanBoardService
    @State private var selectedTask: KanbanTaskSelection?
    @State private var showCreateTask = false
    @State private var blockPromptTask: KanbanTaskCard?
    @State private var blockReason = ""
    @State private var deletePromptTask: KanbanTaskCard?
    @State private var reclaimPromptTask: KanbanTaskCard?

    var body: some View {
        VStack(spacing: 12) {
            switch service.availability {
            case .unknown, .checking:
                if let snapshot = service.snapshot {
                    boardContent(snapshot)
                } else {
                    Spacer()
                    ProgressView("Loading board…")
                        .tint(.conduitAccent)
                    Spacer()
                }
            case .unavailable:
                ContentUnavailableView(
                    "Kanban Not Enabled",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Enable the kanban plugin on this Hermes gateway to see the board.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signInRequired:
                ContentUnavailableView(
                    "Sign-In Expired",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Refresh your dashboard sign-in to see the board.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                if let snapshot = service.snapshot {
                    boardContent(snapshot)
                } else {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "Couldn't Load",
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                        Button {
                            Haptics.selection()
                            Task { await service.loadBoard() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .frame(height: 44)
                        }
                        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .available:
                if let snapshot = service.snapshot {
                    boardContent(snapshot)
                }
            }
        }
        .task(id: ObjectIdentifier(service)) {
            defer { service.stopEventStreaming() }
            await service.loadBoard()
            await service.loadBoards()
            await service.loadAssignees()
            service.startEventStreaming()
            // The events stream makes updates instant; this quiet loop stays
            // as the fallback safety net (and self-heals the stream after
            // availability recovers). SwiftUI cancels this task the moment
            // the tab loses identity (tab switch, dismissal, server change).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                await service.loadBoard(quiet: true)
                service.startEventStreaming()
            }
        }
        .sheet(item: $selectedTask) { selection in
            KanbanTaskDetailSheet(service: service, taskID: selection.id)
        }
        .sheet(isPresented: $showCreateTask) {
            KanbanTaskCreateSheet(service: service)
        }
        .alert("Block task?", isPresented: Binding(
            get: { blockPromptTask != nil },
            set: { if !$0 { blockPromptTask = nil } }
        )) {
            TextField("Reason (optional)", text: $blockReason)
            Button("Block") {
                if let task = blockPromptTask {
                    let reason = blockReason
                    Task { await service.moveTask(task.id, to: KanbanStatus.blocked.rawValue, blockReason: reason) }
                }
                blockPromptTask = nil
                blockReason = ""
            }
            Button("Cancel", role: .cancel) {
                blockPromptTask = nil
                blockReason = ""
            }
        } message: {
            Text("The dispatcher skips blocked tasks until they are unblocked.")
        }
        .alert("Delete task?", isPresented: Binding(
            get: { deletePromptTask != nil },
            set: { if !$0 { deletePromptTask = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let task = deletePromptTask {
                    Task { await service.deleteTask(task.id) }
                }
                deletePromptTask = nil
            }
            Button("Cancel", role: .cancel) { deletePromptTask = nil }
        } message: {
            Text("This permanently deletes the task and cannot be undone.")
        }
        .alert("Reclaim run?", isPresented: Binding(
            get: { reclaimPromptTask != nil },
            set: { if !$0 { reclaimPromptTask = nil } }
        )) {
            Button("Reclaim") {
                if let task = reclaimPromptTask {
                    Task { await service.reclaimTask(task.id) }
                }
                reclaimPromptTask = nil
            }
            Button("Cancel", role: .cancel) { reclaimPromptTask = nil }
        } message: {
            Text("Stops the running worker and returns the task to Ready.")
        }
    }

    private func handleMenuAction(_ task: KanbanTaskCard, _ action: KanbanCardMenuAction) {
        switch action {
        case .move(let status):
            Task { await service.moveTask(task.id, to: status) }
        case .promptBlock:
            blockReason = ""
            blockPromptTask = task
        case .promptReclaim:
            Haptics.warning()
            reclaimPromptTask = task
        case .promptDelete:
            Haptics.warning()
            deletePromptTask = task
        case .reassign(let assignee):
            Task { await service.reassignTask(task.id, to: assignee) }
        case .adjustPriority(let delta):
            Task { await service.setPriority(task.id, to: task.priority + delta) }
        case .clearPriority:
            Task { await service.setPriority(task.id, to: 0) }
        }
    }

    @ViewBuilder
    private func boardContent(_ snapshot: KanbanBoardSnapshot) -> some View {
        boardHeader(snapshot)
        if let error = service.lastActionError {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .id(error.id)
        } else if let notice = service.lastActionNotice {
            Label(notice, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(snapshot.columns) { column in
                    KanbanColumnView(
                        column: column,
                        assignees: service.assigneeOptions.isEmpty ? snapshot.assignees : service.assigneeOptions,
                        isMutating: { service.mutatingTaskID == $0 },
                        onSelect: { taskID in
                            selectedTask = KanbanTaskSelection(id: taskID)
                        },
                        onMenuAction: handleMenuAction
                    )
                    .containerRelativeFrame(.horizontal, count: 10, span: 9, spacing: 12)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }

    private func boardHeader(_ snapshot: KanbanBoardSnapshot) -> some View {
        HStack(spacing: 10) {
            Menu {
                if !service.boards.isEmpty {
                    ForEach(service.boards) { board in
                        Button {
                            Haptics.selection()
                            Task { await service.selectBoard(board.slug) }
                        } label: {
                            if isSelected(board) {
                                Label(board.name, systemImage: "checkmark")
                            } else {
                                Text(board.name)
                            }
                        }
                    }
                    Divider()
                }
                Button {
                    Haptics.selection()
                    Task { await service.setIncludeArchived(!service.includeArchived) }
                } label: {
                    if service.includeArchived {
                        Label("Show archived", systemImage: "checkmark")
                    } else {
                        Text("Show archived")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentBoardName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("\(snapshot.taskCount) \(snapshot.taskCount == 1 ? "task" : "tasks")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if service.streamConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Live updates")
            }
            if service.isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                Haptics.selection()
                showCreateTask = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.conduitAccent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New task")
        }
        .padding(.horizontal, 4)
    }

    private var currentBoardName: String {
        if let slug = service.selectedBoardSlug {
            return service.boards.first(where: { $0.slug == slug })?.name ?? slug
        }
        if let current = service.serverCurrentBoard {
            return service.boards.first(where: { $0.slug == current })?.name ?? current
        }
        return "Board"
    }

    private func isSelected(_ board: KanbanBoardSummary) -> Bool {
        if let slug = service.selectedBoardSlug {
            return board.slug == slug
        }
        return board.slug == service.serverCurrentBoard
    }
}

private struct KanbanTaskSelection: Identifiable {
    let id: String
}

enum KanbanCardMenuAction {
    case move(String)
    case promptBlock
    case promptReclaim
    case promptDelete
    case reassign(String?)
    case adjustPriority(Int)
    case clearPriority
}

private struct KanbanColumnView: View {
    let column: KanbanColumn
    let assignees: [String]
    let isMutating: (String) -> Bool
    let onSelect: (String) -> Void
    let onMenuAction: (KanbanTaskCard, KanbanCardMenuAction) -> Void

    private var tint: Color { column.status?.tint ?? .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: column.status?.systemImage ?? "square.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(column.status?.displayName ?? column.name.capitalized)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(column.tasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.13), in: Capsule())
            }
            .padding(.horizontal, 4)

            if column.tasks.isEmpty {
                Text("No tasks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(column.tasks) { task in
                            Button {
                                Haptics.selection()
                                onSelect(task.id)
                            } label: {
                                KanbanTaskCardView(task: task)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { cardMenu(for: task) }
                            .accessibilityHint("Touch and hold for task actions.")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Context menu per card. Running tasks are dispatcher-owned: the only
    /// action is reclaiming the run (moves and reassignment are rejected
    /// server-side while a worker holds the claim).
    @ViewBuilder
    private func cardMenu(for task: KanbanTaskCard) -> some View {
        let inFlight = isMutating(task.id)
        if task.kanbanStatus == .running {
            Button {
                onMenuAction(task, .promptReclaim)
            } label: {
                Label("Reclaim", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(inFlight)
        } else {
            Menu("Move to") {
                ForEach(KanbanStatus.moveTargets(excluding: task.status), id: \.rawValue) { status in
                    Button {
                        Haptics.selection()
                        onMenuAction(task, status == .blocked ? .promptBlock : .move(status.rawValue))
                    } label: {
                        Label(status.displayName, systemImage: status.systemImage)
                    }
                }
            }
            .disabled(inFlight)

            Menu("Assign to") {
                if task.assignee != nil {
                    Button {
                        Haptics.selection()
                        onMenuAction(task, .reassign(nil))
                    } label: {
                        Label("Unassign", systemImage: "person.slash")
                    }
                }
                ForEach(assignees, id: \.self) { assignee in
                    Button {
                        Haptics.selection()
                        onMenuAction(task, .reassign(assignee))
                    } label: {
                        if assignee == task.assignee {
                            Label(assignee, systemImage: "checkmark")
                        } else {
                            Text(assignee)
                        }
                    }
                }
            }
            .disabled(inFlight)

            Button {
                Haptics.selection()
                onMenuAction(task, .adjustPriority(1))
            } label: {
                Label("Raise priority", systemImage: "chevron.up.2")
            }
            .disabled(inFlight)

            Button {
                Haptics.selection()
                onMenuAction(task, .adjustPriority(-1))
            } label: {
                Label("Lower priority", systemImage: "chevron.down.2")
            }
            .disabled(inFlight)

            if task.priority != 0 {
                Button {
                    Haptics.selection()
                    onMenuAction(task, .clearPriority)
                } label: {
                    Label("Clear priority", systemImage: "minus.circle")
                }
                .disabled(inFlight)
            }

            Divider()

            Button(role: .destructive) {
                onMenuAction(task, .promptDelete)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(inFlight)
        }
    }
}

private struct KanbanTaskCardView: View {
    let task: KanbanTaskCard

    private var isBlocked: Bool { task.kanbanStatus == .blocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if task.priority != 0 {
                    Image(systemName: task.priority > 0 ? "chevron.up.2" : "chevron.down.2")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(task.priority > 0 ? Color.conduitAccent : .secondary)
                }
            }

            if let summary = task.latestSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if isBlocked, let reason = task.blockReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                if let assignee = task.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.conduitAura.opacity(0.14), in: Capsule())
                }
                if let progress = task.progress {
                    badge("checklist", "\(progress.done)/\(progress.total)")
                }
                if task.commentCount > 0 {
                    badge("bubble", "\(task.commentCount)")
                }
                if task.linkCounts.parents + task.linkCounts.children > 0 {
                    badge("link", "\(task.linkCounts.parents + task.linkCounts.children)")
                }
                if task.consecutiveFailures > 0 {
                    badge("flame", "\(task.consecutiveFailures)", tint: .orange)
                }
                if let warnings = task.warnings, warnings.count > 0 {
                    badge(
                        "exclamationmark.triangle.fill",
                        "\(warnings.count)",
                        tint: warnings.highestSeverity == "critical" || warnings.highestSeverity == "error" ? .red : .orange
                    )
                }
                Spacer(minLength: 0)
                if let age = KanbanNormalizer.ageLabel(task.age.createdAgeSeconds) {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isBlocked ? Color.orange.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func badge(_ systemImage: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
    }
}
