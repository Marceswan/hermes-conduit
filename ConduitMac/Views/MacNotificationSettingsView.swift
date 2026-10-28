import AppKit
import SwiftUI
import UserNotifications

enum MacNotificationAuthorizationState: Equatable {
    case notDetermined, denied, allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .allowed
        }
    }

    var statusText: String {
        switch self {
        case .notDetermined: return AppLocalization.string("Conduit will ask the first time it needs to")
        case .denied: return AppLocalization.string("Blocked in System Settings")
        case .allowed: return AppLocalization.string("Allowed")
        }
    }

    var needsSystemSettings: Bool { self == .denied }
}

struct MacNotificationSettingsView: View {
    @ObservedObject var preferences: MacNotificationPreferences
    @State var authorization: MacNotificationAuthorizationState
    /// The count on the Dock icon (D31). It is not a notification: it follows none of the toggles above.
    @AppStorage private var showsDockCount: Bool
    /// What System Settings says about badges, as last read. Nil until the first read, so no note shows early.
    @State private var badgePermission: MacBadgePermission?
    /// Nil is the live notification center (the XCTest host has none); tests pass a fake.
    private let client: MacNotificationCenterClient?
    private let requester: MacBadgeOptionRequester
    private let bundleID: String?
    private let openURL: @MainActor (URL) -> Void

    init(
        preferences: MacNotificationPreferences = .shared,
        authorization: MacNotificationAuthorizationState = .notDetermined,
        dockDefaults: UserDefaults = .standard,
        client: MacNotificationCenterClient? = nil,
        requester: MacBadgeOptionRequester = .shared,
        bundleID: String? = Bundle.main.bundleIdentifier,
        openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.preferences = preferences
        _authorization = State(initialValue: authorization)
        _showsDockCount = AppStorage(wrappedValue: MacDockBadge.defaultValue, MacDockBadge.defaultsKey, store: dockDefaults)
        self.client = client
        self.requester = requester
        self.bundleID = bundleID
        self.openURL = openURL
    }

    static func kindControlsEnabled(_ preferences: MacNotificationPreferences) -> Bool { preferences.isEnabled }

    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("On this Mac"), symbol: "bell.badge", tint: .conduitAccent) {
            Toggle(AppLocalization.string("Notify me when Conduit needs me"), isOn: $preferences.isEnabled)
            Group {
                Toggle(AppLocalization.string("A long reply finishes"), isOn: $preferences.notifiesDone)
                Toggle(AppLocalization.string("Hermes needs an approval"), isOn: $preferences.notifiesApprovals)
                Toggle(AppLocalization.string("Hermes asks a question"), isOn: $preferences.notifiesQuestions)
                Picker(AppLocalization.string("Count a reply as long after"), selection: $preferences.threshold) {
                    ForEach(MacNotificationPolicy.thresholdChoices, id: \.self) { seconds in
                        Text(Self.thresholdLabel(seconds)).tag(seconds)
                    }
                }
                Toggle(AppLocalization.string("Play a sound"), isOn: $preferences.soundEnabled)
            }
            .disabled(!Self.kindControlsEnabled(preferences))
            Toggle(AppLocalization.string("Show count on Dock icon"), isOn: $showsDockCount)
            if badgePermission?.needsNote(showsCount: showsDockCount) == true {
                // macOS shows no Dock count while badges are off for Conduit (D31 fix).
                Text(AppLocalization.string("Mac.DockBadge.PermissionNote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppLocalization.string("Open System Settings")) {
                    openURL(MacNotificationSettingsLink.url(bundleID: bundleID))
                }
            }
            SettingsMetricRow(
                label: AppLocalization.string("Status"),
                value: authorization.statusText,
                valueColor: authorization == .allowed ? .green : .secondary
            )
            if authorization.needsSystemSettings {
                Button(AppLocalization.string("Open System Settings")) { NSWorkspace.shared.open(Self.systemSettingsURL) }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        // The XCTest host has no usable notification center.
        guard let center = client ?? (MacDefaults.isRunningUnderXCTest ? nil : UNMacNotificationCenterClient()) else { return }
        let permission = await requester.refresh(on: center, wantsBadge: showsDockCount)
        badgePermission = permission
        authorization = MacNotificationAuthorizationState(permission.status)
    }

    private static func thresholdLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 120 ? [.minute] : [.second]
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = AppLocalization.formattingLocale
            return calendar
        }()
        return formatter.string(from: seconds) ?? "\(Int(seconds))"
    }
}
