import SwiftUI

// Mac twin of AuthWebSignInSheet and AuthWebView.asSignInSheet() in Conduit/Views/LoginView.swift (R2); keep in sync
// (PORTING_LEDGER). The browser sign-in as a sheet: the dashboard page under a bar with Cancel. Upstream adds the
// passkey notice (Conduit/Views/Login/AuthWebPasskeyNotice.swift, excluded on Mac: iOS wording, iOS WebView
// restriction); the Mac AuthWebView twin installs no passkey detector, so this sheet shows none.
struct AuthWebSignInSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let webView: AuthWebView
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            webView
                .navigationTitle(Text("Sign in"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppLocalization.string("Cancel")) { dismiss() }
                            .accessibilityIdentifier("login.browser-sign-in.cancel")
                    }
                }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
    }
}

extension AuthWebView {
    /// The sign-in page as its sheet's content, with a Cancel button.
    func asSignInSheet() -> AuthWebSignInSheet {
        AuthWebSignInSheet(webView: self)
    }
}
