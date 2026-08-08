//
//  KanbanTaskCreateSheet.swift
//  Conduit
//

import SwiftUI

struct KanbanTaskCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: KanbanBoardService

    @State private var title = ""
    @State private var body_ = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var triage = false
    @State private var isCreating = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                Form {
                    Section {
                        TextField("e.g. Fix the reconnect race", text: $title)
                            .textInputAutocapitalization(.sentences)
                    } header: {
                        Text("Title")
                    } footer: {
                        Text("A short imperative summary of the work.")
                    }

                    Section {
                        TextEditor(text: $body_)
                            .frame(minHeight: 120)
                    } header: {
                        Text("Description")
                    } footer: {
                        Text("Optional. Markdown is supported; the worker agent reads this as its brief.")
                    }

                    Section {
                        Menu {
                            Button {
                                assignee = ""
                            } label: {
                                if assignee.isEmpty {
                                    Label("Unassigned", systemImage: "checkmark")
                                } else {
                                    Text("Unassigned")
                                }
                            }
                            ForEach(assigneeOptions, id: \.self) { option in
                                Button {
                                    assignee = option
                                } label: {
                                    if option == assignee {
                                        Label(option, systemImage: "checkmark")
                                    } else {
                                        Text(option)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("Assignee")
                                Spacer()
                                Text(assignee.isEmpty ? "Unassigned" : assignee)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Stepper("Priority: \(priority)", value: $priority, in: -2...2)

                        Toggle("Send to triage", isOn: $triage)
                    } header: {
                        Text("Dispatch")
                    } footer: {
                        Text("Assigned tasks with no pending dependencies start in Ready and get picked up by the dispatcher. Triage tasks wait for review first.")
                    }

                    if let validationMessage {
                        Section {
                            Label(validationMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createTask() }
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var assigneeOptions: [String] {
        service.assigneeOptions.isEmpty ? (service.snapshot?.assignees ?? []) : service.assigneeOptions
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    private func createTask() async {
        isCreating = true
        validationMessage = nil
        let created = await service.createTask(
            title: title,
            body: body_.isEmpty ? nil : body_,
            assignee: assignee.isEmpty ? nil : assignee,
            priority: priority,
            triage: triage
        )
        isCreating = false
        if created {
            Haptics.success()
            dismiss()
        } else {
            Haptics.error()
            validationMessage = service.lastActionError?.message ?? "Hermes could not create this task."
        }
    }
}
