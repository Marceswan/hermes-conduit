// Mac twin of Conduit/Voice/HermesNativeCalls.swift (R3); keep in sync (PORTING_LEDGER): same members as the Mac-compiled call sites use.
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
