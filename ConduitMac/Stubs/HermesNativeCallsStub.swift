import Foundation

/// Calls from Hermes ring through CallKit and PushKit on iPhone only.
@MainActor
final class HermesNativeCalls: NSObject {
    static let shared = HermesNativeCalls()
    static let ringsKey = "hermesCalls.ringsLikeCall"
    static var ringingWanted: Bool { false }
    static var offersRinging: Bool { false }

    func activate() {}
    func ringingSettingChanged() {}
    func routedAnswerFailed(_ target: ConduitNotificationTarget) {}
    func answeredOnWatch(ringID: String) -> ConduitNotificationTarget? { nil }
}
