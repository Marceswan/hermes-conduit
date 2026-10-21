// Mac twin of Conduit/CarPlay/CarPlayVoiceCoordinator.swift and CarPlayVoiceTemplateFactory.swift (R2); keep in sync (PORTING_LEDGER).
import Foundation

/// CarPlay has no Mac counterpart. Shared code reports voice state changes
/// here; on Mac nobody is listening.
@MainActor
final class CarPlayVoiceCoordinator {
    static let shared = CarPlayVoiceCoordinator()

    func voiceModeChanged(in appState: AppState) {}
    func conversationStartingOnPhone(in appState: AppState) {}

    static func awaitConnection(of appState: AppState, timeout: Duration) async -> Bool { false }
}

struct CarPlayVoiceControls: Equatable {
    /// The classic voice mode, as opposed to a live call.
    var isClassic: Bool
    var isMicrophoneMuted: Bool
    /// What the Error state names as the thing to fix; nil shows the
    /// generic Error title. A state's title is as fixed as its buttons, so
    /// a new issue also needs a new template.
    var errorIssue: VoiceSetupIssue? = nil
    /// The chat Listen talks in, which the Ready title names; nil when
    /// Listen starts a new one. Fixed like the other titles, so a different
    /// chat also needs a new template.
    var chatTitle: String? = nil

    /// The classic mode's Listen continues the current chat, so a new chat
    /// is its own button. A live call always starts fresh.
    var offersNewChat: Bool { isClassic }

    static let initial = CarPlayVoiceControls(isClassic: true, isMicrophoneMuted: false)
}
