import AppKit
import Foundation

/// User-facing text for a failed window capture. Cancel never reaches here.
enum MacAskAboutWindowMessage {
    static func message(for failure: MacWindowCaptureMath.Failure) -> String {
        switch failure {
        case .pickerFailed: return AppLocalization.string("Couldn't open the window picker.")
        case .noPicture: return AppLocalization.string("Couldn't capture that window.")
        case .encodeFailed: return AppLocalization.string("Couldn't prepare the window image.")
        }
    }
}

/// Chat > "Ask About Window...": pick one window, capture it, attach it to the
/// current chat as the pending screenshot.
@MainActor
enum MacAskAboutWindow {
    static func run(appState: AppState, window: NSWindow?, service: MacWindowCaptureService = .shared) async {
        guard !MacKeyboardActions.commandsBlocked(by: window) else { return }
        let megabytes = AttachmentSizeLimit.clampedMegabytes(
            UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        )
        let outcome = await service.capture(limitBytes: AttachmentSizeLimit.byteLimit(megabytes: megabytes))
        await attach(outcome, appState: appState, limitMegabytes: megabytes)
    }

    /// All post-capture logic. The target chat is read after the picker
    /// returns, so a chat re-keyed meanwhile still receives the screenshot.
    static func attach(_ outcome: MacWindowCaptureOutcome, appState: AppState, limitMegabytes: Int) async {
        switch outcome {
        case .cancelled:
            return
        case .failed(let failure):
            appState.errorMessage = MacAskAboutWindowMessage.message(for: failure)
        case .tooLarge(let name):
            appState.errorMessage = AttachmentSizeLimit.tooLargeMessage(names: [name], megabytes: limitMegabytes)
        case .captured(let data, _, let name):
            if appState.activeSessionId == nil {
                await appState.createNewSession()
            }
            guard let sessionID = appState.activeSessionId else {
                if appState.errorMessage == nil {
                    appState.errorMessage = AppLocalization.string("Couldn't start a new chat. Check your connection and try again.")
                }
                return
            }
            switch AttachmentStaging.stageScreenshot(data: data, filename: name, limitMegabytes: limitMegabytes) {
            case .staged(let attachment):
                appState.setPendingScreenshot(attachment, forSession: sessionID)
            case .tooLarge(let n):
                appState.errorMessage = AttachmentSizeLimit.tooLargeMessage(names: [n], megabytes: limitMegabytes)
            case .failed:
                appState.errorMessage = MacAskAboutWindowMessage.message(for: .encodeFailed)
            }
        }
    }
}
