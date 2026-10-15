import SwiftUI

/// The "Notch status" row of Settings > On this device (inserted by one gated
/// line in AuxiliaryViews.swift, next to the Spotlight row).
struct MacNotchStatusSettingsSection: View {
    @AppStorage(NotchStatusSettings.key) private var raw = NotchMode.activeAgents.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(AppLocalization.string("Notch status"), selection: $raw) {
                Text("Active agents").tag(NotchMode.activeAgents.rawValue)
                Text("Only when I'm needed").tag(NotchMode.onlyWhenNeeded.rawValue)
                Text("Off").tag(NotchMode.off.rawValue)
            }
            .pickerStyle(.menu)
            Text("Shows what Hermes is doing at the top of the screen. It only sees chats on this connection: chats started from the CLI, Slack or another app are not shown.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }
}
