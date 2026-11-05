import AppIntents

/// Opens a chat in Conduit (D19). The chat is picked in the Shortcuts UI;
/// the saved id resolves even when the app has just launched.
struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Conduit Chat"
    static var description = IntentDescription("Open a chat in Conduit.")

    /// The value must be a boolean literal: the App Intents metadata
    /// processor rejects computed values for this property.
    static var openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Chat") var session: ConduitSessionEntity

    init() {}
    init(session: ConduitSessionEntity) { self.session = session }

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentInbox.shared.enqueue(.openSession(id: session.id, profile: session.profile))
        return .result()
    }
}
