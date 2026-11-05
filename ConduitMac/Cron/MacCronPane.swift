import SwiftUI

// Mac twin of V2TasksView.swift create actions; keep in sync
/// The Cron pane on Mac: upstream `CronList`, with New job and From a
/// blueprint above it. `CronList` draws the pane title, the counts and the
/// search field, so the action row has no title of its own.
struct MacCronPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var editorTarget: CronJobEditorSheet.Target?
    @State private var showingBlueprints = false
    /// A job a blueprint just made, opened once the gallery has closed.
    @State private var createdJob: CronJob?
    @State private var detailJob: CronJob?

    init() {}

    /// The rule upstream uses for Edit job: the dashboard bridge exists and no
    /// job action runs.
    static func createActionsEnabled(hasDashboardBridge: Bool, cronJobActionID: String?) -> Bool {
        hasDashboardBridge && cronJobActionID == nil
    }

    /// The job whose detail opens when the blueprint gallery closes.
    static func jobToOpen(afterGalleryClosedWith created: CronJob?) -> CronJob? {
        created
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    editorTarget = .create
                } label: {
                    Label(AppLocalization.string("New job"), systemImage: "plus")
                }
                .buttonStyle(.settingsPrimary)
                Button {
                    showingBlueprints = true
                } label: {
                    Label(AppLocalization.string("From a blueprint"), systemImage: "square.grid.2x2")
                }
                .buttonStyle(.settings)
            }
            .disabled(!Self.createActionsEnabled(
                hasDashboardBridge: appState.dashboardTicketBridge != nil,
                cronJobActionID: appState.cronJobActionID))
            CronList()
        }
        .sheet(item: $editorTarget) {
            CronJobEditorSheet(target: $0)
                .environmentObject(appState)
                .macFormSheetSize()
        }
        .sheet(isPresented: $showingBlueprints, onDismiss: {
            if let job = Self.jobToOpen(afterGalleryClosedWith: createdJob) {
                createdJob = nil
                detailJob = job
            }
        }) {
            CronBlueprintGallerySheet { createdJob = $0 }
                .environmentObject(appState)
                .macFormSheetSize()
        }
        .sheet(item: $detailJob) {
            CronJobDetailSheet(job: $0)
                .environmentObject(appState)
        }
    }
}
