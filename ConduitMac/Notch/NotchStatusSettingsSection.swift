import SwiftUI

/// The "Notch status" and "Notch style" rows of Settings > On this device (inserted by one gated
/// line in AuxiliaryViews.swift, next to the Spotlight row).
struct MacNotchStatusSettingsSection: View {
    @AppStorage(NotchStatusSettings.key) private var raw = NotchMode.activeAgents.rawValue
    @AppStorage(NotchStatusSettings.surfaceStyleKey) private var styleRaw = NotchSurfaceStyle.glass.rawValue

    /// An unknown stored value reads as the default, as the settings object does.
    private var style: Binding<NotchSurfaceStyle> {
        Binding(get: { NotchSurfaceStyle(rawValue: styleRaw) ?? .glass }, set: { styleRaw = $0.rawValue })
    }

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
            Picker(AppLocalization.string("Notch style"), selection: style) {
                ForEach(NotchSurfaceStyle.allCases) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            Text(verbatim: style.wrappedValue.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !NotchSurfaceStyle.glassAvailable {
                Text("Glass needs macOS 26 or later. Until then the notch is drawn Solid black.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
    }
}
