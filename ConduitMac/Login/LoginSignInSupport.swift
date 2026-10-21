import SwiftUI

// Mac-only support types for the frozen sign-in copies (ConduitMac/Login/LoginView.swift and
// ConnectionSetupView.swift), kept out of those files so a sync diff against upstream stays small.
// Task 7c (R17): see docs/macos/PORTING_LEDGER.md.

// MARK: - Sign-in decision (R17)

/// The next step for a dashboard's discovery answer, as a plain value so the mapping is unit-testable.
enum LoginSignInRoute: Equatable {
    case password
    case browser
    case nativeOAuth(provider: String?)
}

extension LoginView {
    /// Decides the next sign-in step. An answer that names no sign-in (a page that is not Hermes, an empty or
    /// unusable provider list) throws the shared `DashboardSignInError`, which classifies as "Unexpected response"
    /// with Try Again and Troubleshoot Connection; it never opens a browser sheet that cannot sign in. A password
    /// dashboard that also offers a browser sign-in (a provider listed without `supports_password`, or a native
    /// provider whose capability check fails) opens that sign-in when nothing is typed in the username and
    /// password fields. A partly typed credential stays on the password path (the card then asks for the rest).
    static func signInRoute(
        for discovery: AuthProviderDiscoveryResult,
        hasTypedCredentials: Bool,
        supportsNativeOAuth: () async throws -> Bool
    ) async throws -> LoginSignInRoute {
        switch discovery {
        case .interactiveSignInRequired:
            return .browser
        case .unrecognized:
            throw DashboardSignInError.unrecognizedServer
        case .providers(let providers, let authFlows):
            let supportsPassword = HermesProviderCheck.supportsPassword(providers)
            let offer = DashboardSignInResolver.browserOffer(providers, advertisedFlows: authFlows)
            if !supportsPassword && offer == nil { throw DashboardSignInError.noSignInMethod }
            if HermesProviderCheck.hasNativeOAuthProvider(providers),
               !supportsPassword || !hasTypedCredentials,
               try await supportsNativeOAuth() {
                return .nativeOAuth(provider: HermesProviderCheck.nativeOAuthProvider(providers))
            }
            if !supportsPassword || (!hasTypedCredentials && offer != nil) { return .browser }
            return .password
        }
    }
}

/// M3: the address field after the active dashboard changed under an open login card.
enum LoginDashboardAddress {
    /// The dashboard's address when the field is empty or still holds what the card filled in itself; nil keeps what
    /// the user typed (or when nothing changes).
    static func refreshed(current: String, autoFilled: String, dashboardURL: String) -> String? {
        let target = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, now != target else { return nil }
        func bare(_ text: String) -> String {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return now.isEmpty || bare(now) == bare(autoFilled) ? target : nil
    }
}

/// K3: the sign-in options the card starts with (upstream: save the sign-in, with Face ID or Touch ID when the Mac
/// has one).
enum LoginSignInDefaults {
    static let saveCredentials = true

    static func useBiometrics(biometricsAvailable: Bool, saveCredentials: Bool) -> Bool {
        biometricsAvailable && saveCredentials
    }
}

// MARK: - Saved sign-in (B5)

/// The card's own control for the active dashboard's saved sign-in, with the wording of upstream's Saved Dashboards
/// row.
struct LoginSavedSignInOffer: Equatable {
    let title: String
    let symbol: String

    /// Nil when nothing is saved, when the saved password needs a Face ID / Touch ID that is gone (that sign-in
    /// then needs typing), and while the session is connected: `switchDashboard(to:)` does nothing for the
    /// connected dashboard, so the button would be a no-op.
    static func make(
        kind: SavedSignInKind,
        biometricKind: BiometricAuth.Kind?,
        biometricsAvailable: Bool,
        isConnected: Bool
    ) -> LoginSavedSignInOffer? {
        guard !isConnected else { return nil }
        switch kind {
        case .biometric:
            guard biometricsAvailable else { return nil }
            return biometricKind == .touchID
                ? LoginSavedSignInOffer(title: AppLocalization.string("Signs in with Touch ID"), symbol: "touchid")
                : LoginSavedSignInOffer(title: AppLocalization.string("Signs in with Face ID"), symbol: "faceid")
        case .password, .session:
            return LoginSavedSignInOffer(title: AppLocalization.string("Saved sign-in"), symbol: "key")
        case .signInNeeded:
            return nil
        }
    }
}

/// What the Keychain read on appear found for the active dashboard.
struct LoginSavedSignIn: Equatable {
    let id: UUID
    let kind: SavedSignInKind
    let address: String
}

struct LoginSavedSignInButton: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let offer: LoginSavedSignInOffer
    let address: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: offer.symbol)
                    .font(.body)
                    .foregroundStyle(.conduitAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(offer.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 14, tint: .conduitAura.opacity(0.06))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("login.saved-sign-in")
    }
}

// MARK: - Connection Setup announcement

enum ConnectionSetupAnnouncement {
    /// The one VoiceOver announcement for a test run's terminal event: the shared wording, except in Settings when
    /// Sign In Again is offered, where it says what the screen says (never "return to the login screen" there).
    static func completion(
        for event: ConnectionSetupTestEvent,
        repairing: Bool,
        settingsReview: ConnectionSetupSettingsReview?
    ) -> String? {
        if let settingsReview, settingsReview.offersSignInAgain {
            switch event {
            case .requiresInteractiveSignIn(.authentication, _), .requiresSignInChoice(.authentication, _):
                return ConnectionSetupSettingsReview.signInAgainMessage(connected: settingsReview.isSessionConnected)
            default:
                break
            }
        }
        return ConnectionSetupTestState.completionAnnouncement(for: event, repairing: repairing)
    }
}
