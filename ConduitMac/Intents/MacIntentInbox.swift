import Foundation

enum MacIntentRequest: Equatable {
    case newChat(profile: String?, message: String?)
    case openSession(id: String, profile: String?)
}

/// What a Shortcuts action asked Conduit to do, parked until Hermes is
/// connected (D19). One slot; the intents are foreground actions, so the
/// newest request is the one the user is looking at.
@MainActor
final class MacIntentInbox: ObservableObject {
    static let shared = MacIntentInbox()

    @Published private(set) var revision = 0
    private var pending: MacIntentRequest?

    var hasPending: Bool { pending != nil }

    func enqueue(_ request: MacIntentRequest) {
        pending = request
        revision += 1
    }

    func take() -> MacIntentRequest? {
        defer { pending = nil }
        return pending
    }
}
