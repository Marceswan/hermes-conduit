import SwiftUI
import UIKit
import OSLog

private let macOAuthLogger = Logger(subsystem: "com.meswan.hermes.mac", category: "native-oauth")

/// Mac twin of NativeOAuth.swift's `SafariAuthenticationView`. There is no
/// in-app Safari sheet on Mac: the authorize URL opens in the default
/// browser, and the loopback listener (`NativeOAuthLoginModel`) catches the
/// redirect. This view only runs the operation and offers Cancel.
struct SafariAuthenticationView: View {
    let url: URL?
    let operation: @MainActor () async throws -> NativeOAuthLoginResult
    let onSuccess: @MainActor (NativeOAuthLoginResult) -> Void
    let onError: @MainActor (Error) -> Void
    let onCancel: () -> Void

    @State private var presentation = NativeOAuthPresentationTask()
    @State private var openedURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Continue signing in in your browser.")
                .multilineTextAlignment(.center)
            Button("Cancel") {
                macOAuthLogger.notice("OAuth stage: user cancelled")
                presentation.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 200)
        .onAppear {
            presentation.start(operation: operation, onSuccess: onSuccess, onError: onError)
            openIfNeeded()
        }
        .onChange(of: url) { _, _ in openIfNeeded() }
        .onDisappear {
            macOAuthLogger.notice("OAuth stage: sign-in view removed")
            presentation.cancel()
        }
    }

    private func openIfNeeded() {
        guard let url, url != openedURL else { return }
        openedURL = url
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
