import AppIntents
import Foundation

enum MacIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unknownProfile(String)
    case unknownChat

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownProfile(let name): return "Conduit has no profile named \(name)."
        case .unknownChat: return "That chat is no longer available."
        }
    }
}

enum NewChatIntentCore {
    static func request(profileID: String?, message: String?, knownProfiles: [String]) throws -> MacIntentRequest {
        if let profileID, !knownProfiles.contains(profileID) { throw MacIntentError.unknownProfile(profileID) }
        return .newChat(profile: profileID, message: MacServiceText.normalize(message))
    }
}

/// Opens Conduit on a new chat, optionally with text in the composer (D19).
/// Never sends: a Shortcut can be imported from anywhere, and sending starts
/// a billed turn.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Conduit Chat"
    static var description = IntentDescription(
        "Open Conduit on a new chat, optionally with text in the message box. The text is never sent for you.")

    /// The value must be a boolean literal: the App Intents metadata
    /// processor rejects computed values for this property.
    static var openAppWhenRun: Bool = true

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Profile") var profile: ConduitProfileEntity?
    @Parameter(title: "Message") var message: String?

    init() {}
    init(profile: ConduitProfileEntity?, message: String?) {
        self.profile = profile
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let known = try await ConduitProfileEntityQuery().suggestedEntities().map(\.id)
        let request = try NewChatIntentCore.request(profileID: profile?.id, message: message, knownProfiles: known)
        MacIntentInbox.shared.enqueue(request)
        return .result()
    }
}
