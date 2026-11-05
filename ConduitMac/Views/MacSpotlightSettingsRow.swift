import SwiftUI

/// State behind the Settings row: the opt-in toggle and the wipe button (D19).
@MainActor
final class MacSpotlightSettingsModel: ObservableObject {
    @Published private(set) var isOn: Bool
    private let indexer: MacSpotlightIndexer
    private let catalog: () -> [SessionSummary]

    init(indexer: MacSpotlightIndexer, catalog: @escaping () -> [SessionSummary]) {
        self.indexer = indexer
        self.catalog = catalog
        self.isOn = indexer.isEnabled
    }

    func setOn(_ on: Bool) {
        indexer.setEnabled(on, catalog: catalog())
        isOn = on
    }

    func removeAll() { indexer.removeAll() }
}

/// Settings > On this device. Spotlight indexing is opt-in because chat titles
/// can hold sensitive text.
struct MacSpotlightSettingsRow: View {
    @StateObject private var model = MacSpotlightSettingsModel(
        indexer: MacSpotlightBinder.shared.indexer,
        catalog: { MacSpotlightBinder.shared.currentCatalog() }
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(AppLocalization.string("Show chats in Spotlight"), isOn: Binding(
                get: { model.isOn }, set: { model.setOn($0) }))
            Text(AppLocalization.string("Chat titles and message counts, not message text. Titles can contain sensitive words, so this is off by default. Chats you open or rename are added again while this is on."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(AppLocalization.string("Remove from Spotlight")) { model.removeAll() }
        }
        .padding(.horizontal, 10)
    }
}
