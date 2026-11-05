import AppKit
import Combine
import SwiftUI

/// State behind the Settings row (D28). The system's answer is the only state: no defaults key holds a
/// copy. The status is read when the model is made, when the row appears and when the app becomes active
/// (the user can change it in System Settings > General > Login Items). Nothing here registers the app
/// unless the user turns the toggle on.
@MainActor
final class MacLaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: MacLoginItemStatus
    @Published private(set) var lastChangeFailed = false
    private let service: MacLoginItemService
    private var activation: AnyCancellable?

    init(service: MacLoginItemService, notificationCenter: NotificationCenter = .default) {
        self.service = service
        self.status = service.status
        activation = notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// On while the system holds Conduit as a login item, also while it waits for the user's approval:
    /// the request is registered, and turning it off calls `unregister()`.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var showsApprovalHelp: Bool { status == .requiresApproval }
    var showsError: Bool { lastChangeFailed || status == .notFound }

    /// Reads the system status again and drops an error that no longer applies.
    func refresh() {
        status = service.status
        lastChangeFailed = false
    }

    func setOn(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastChangeFailed = false
        } catch {
            lastChangeFailed = true
        }
        // The toggle shows what the system says, also after an error.
        status = service.status
    }

    func openLoginItemsSettings() { service.openSystemSettingsLoginItems() }
}

/// Settings > On this device. Conduit opens at login only when the user asks. A login launch opens the
/// app the normal way (D28).
struct MacLaunchAtLoginSettingsRow: View {
    @StateObject private var model: MacLaunchAtLoginModel

    init(model: @autoclosure @escaping @MainActor () -> MacLaunchAtLoginModel = MacLaunchAtLoginModel(service: MacLiveLoginItemService())) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(AppLocalization.string("Mac.LaunchAtLogin.Toggle"), isOn: Binding(
                get: { model.isOn }, set: { model.setOn($0) }))
            Text(AppLocalization.string("Mac.LaunchAtLogin.Note"))
                .font(.footnote).foregroundStyle(.secondary)
            if model.showsApprovalHelp {
                Text(AppLocalization.string("Mac.LaunchAtLogin.RequiresApproval"))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(AppLocalization.string("Mac.LaunchAtLogin.OpenSettings")) { model.openLoginItemsSettings() }
            }
            if model.showsError {
                Text(AppLocalization.string("Mac.LaunchAtLogin.Failed"))
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .onAppear { model.refresh() }
    }
}
