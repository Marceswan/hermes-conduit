import Foundation

/// Mac wording for text that lives in `Shared/`, which the Apple Watch app compiles too.
///
/// `scripts/check-l10n-coverage.py` reads every `AppLocalization.string("...")` literal in
/// `Shared/GeminiLive` against the Watch catalog, and a `Mac.` key is not in that catalog (the Watch
/// never runs the Mac branch). The literal therefore sits here, in a Mac-only file the checker does
/// not scan. `MacWordingTests` checks that the key exists with all languages and resolves in the bundle.
enum MacSharedWording {
    /// `GeminiLiveSession.refusalMessage`: "Click Try again" for upstream's "Tap Try again".
    static var geminiLiveResumptionLost: String {
        AppLocalization.string("Mac.GeminiLive.ResumptionLost")
    }
}
