import Combine
import Foundation

/// No Apple Watch pairs with a Mac. Watch alerts reach the Watch via the
/// iPhone app (spec: Notifications), so this link never activates.
@MainActor
final class WatchVoiceLink: ObservableObject {
    static let shared = WatchVoiceLink()

    // Read by WatchSettingsSection.
    @Published private(set) var isActivated = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false

    let log = WatchPhoneCallLog.shared
    private(set) lazy var direct = WatchDirectBroker(link: self)

    private init() {}

    func activate() {}

    static var appStateName: String { "active" }

    func startAnsweredCall(_ start: WatchVoiceWire.Message, reply: @escaping ([String: Any]) -> Void) {
        reply([:])
    }

    func share(_ context: WatchPhoneContext) {}
}
