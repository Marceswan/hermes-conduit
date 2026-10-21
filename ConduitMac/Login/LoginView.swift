// keep in sync: frozen copy of Conduit/Views/LoginView.swift at macos e27dc4db (user decision 2026-10-21 item 2B)
//
//  LoginView.swift
//  Conduit
//
//  Connect to a Hermes dashboard instance.
//  Uses an authenticated WebView approach — the dashboard issues a one-time
//  ticket that we use for the WebSocket connection.
//

import SwiftUI
import WebKit
import os

struct LoginView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    private static let logger = Logger(subsystem: "com.milim.relay", category: "login")

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredentials = LoginSignInDefaults.saveCredentials
    @State private var useFaceID = false
    /// The address the card filled in itself (from the last dashboard), so a dashboard switch under an open card
    /// can replace it, and an address the user typed stays.
    @State private var autoFilledURL = ""
    /// How the active dashboard can sign in without typing (B5), read from the Keychain on appear, not in `body`.
    @State private var savedSignIn: LoginSavedSignIn?
    /// True while a tap on the saved sign-in is in flight, so a second click cannot start a second unlock.
    @State private var isSigningInSaved = false
    /// Read on appear rather than per view init (each read is a
    /// LocalAuthentication round trip), and again on return to the
    /// foreground, where a fingerprint or face may just have been set up.
    @State private var biometrics = BiometricAuth.Status(kind: nil, isAvailable: false)
    @State private var biometricsLoaded = false
    @Environment(\.scenePhase) private var scenePhase
    @State var cloudflareEnabled = false
    @State var cloudflareClientID = ""
    @State var cloudflareClientSecret = ""
    @State private var isConnecting = false
    @State private var showWebView = false
    @State private var showNativeOAuth = false
    @State private var nativeOAuthProvider: String?
    @State private var nativeOAuthBaseURL = ""
    @State private var nativeOAuthDashboardID = UUID()
    /// The presented failure state: classified connection failures with
    /// recovery actions, or plain validation notices. The view never renders
    /// raw Foundation error strings directly.
    @State private var failure: ConnectionFailurePresentation?
    /// Non-nil presents the Connection Setup shell, pre-seeded with the
    /// classified help destination (or `.start` from the entry point).
    @State private var connectionSetupDestination: ConnectionHelpDestination?
    /// Round 6: non-nil presents Repair Connection, seeded from the failed
    /// saved-credential reconnect.
    @State private var connectionRepairContext: ConnectionRepairContext?
    /// Whether a repairable saved connection exists, computed once when a
    /// failure is presented (pure reads in `body`; the takeover happens at
    /// tap time).
    @State private var savedRepairAvailable = false
    /// Set only by the user's Cloudflare toggle (never by the onAppear
    /// Keychain restore), so a returning saved-token user is not scrolled
    /// away from the top of the form every time the login screen appears.
    @State private var revealCloudflareSection = false
    @State private var showExtraHeaders = false
    /// Bumped when the extra-headers sheet saves so the row's count refreshes.
    @State private var extraHeadersRevision = 0
    /// The WebKit session store used for the CURRENT browser sign-in (#148):
    /// the registered dashboard's own identified store when one exists, or a
    /// fresh per-presentation identity for a dashboard being added. Set at
    /// sign-in intent (not render time), so a store is only created when the
    /// user actually begins a browser sign-in.
    @State private var signInWebKitStoreID: UUID?
    @FocusState private var focusedField: LoginField?

    private var biometricToggleTitle: String {
        biometrics.kind == .touchID
            ? AppLocalization.string("Use Touch ID")
            : AppLocalization.string("Use Face ID")
    }

    private var biometricFootnote: String {
        switch (biometrics.kind, biometrics.isAvailable, useFaceID) {
        case (.touchID, false, _):
            return AppLocalization.string("Touch ID is not available on this device. You can still save credentials.")
        case (.touchID, true, true):
            return AppLocalization.string("Touch ID, with device passcode recovery, is required on launch.")
        case (.touchID, true, false):
            return AppLocalization.string("Saved credentials reconnect without a Touch ID prompt.")
        case (.faceID, true, true):
            return AppLocalization.string("Face ID, with device passcode recovery, is required on launch.")
        case (.faceID, true, false):
            return AppLocalization.string("Saved credentials reconnect without a Face ID prompt.")
        case (.faceID, false, _), (nil, _, _):
            return AppLocalization.string("Face ID is not available on this device. You can still save credentials.")
        }
    }

    var body: some View {
        ZStack {
            // Purely decorative: the scroll content fills the screen, so
            // keyboard dismissal is owned by scroll-dismiss, the keyboard
            // Done button, and moving focus between fields.
            ConduitBackdrop(drifts: true)

            // The login form is a responsive scroll view inside a fixed
            // decorative layer: at compact iPhone heights with the keyboard
            // up, the focused field (including the optional Cloudflare fields
            // near the bottom) scrolls into view instead of hiding behind the
            // keyboard. minHeight keeps the centered layout when the content
            // fits and only introduces scrolling when it cannot.
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        loginContent
                            .frame(minHeight: geometry.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // No soft keyboard on Mac: no scroll-to-focus on focus changes (it clipped the header).
                    .onChange(of: revealCloudflareSection) { _, requested in
                        guard requested else { return }
                        revealCloudflareSection = false
                        // Defer one runloop turn: the CF fields this scroll
                        // targets are inserted in the same transaction, and
                        // scrolling to not-yet-installed ids would no-op.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(LoginField.cloudflareClientID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            biometrics = BiometricAuth.status
            if !biometrics.isAvailable { useFaceID = false }
        }
        .onAppear {
            biometrics = BiometricAuth.status
            if !biometricsLoaded {
                useFaceID = LoginSignInDefaults.useBiometrics(
                    biometricsAvailable: biometrics.isAvailable, saveCredentials: saveCredentials)
            }
            biometricsLoaded = true
            refreshSavedSignIn()
            guard serverUrl.isEmpty else { return }
            fillAddress(appState.lastDashboardURL)
        }
        .onChange(of: appState.activeDashboardID) { _, newID in
            // The dashboard switcher also shows over this card: the address and the Cloudflare token it holds belong
            // to the dashboard that was active when the card opened.
            refreshSavedSignIn()
            guard let newID, let dashboard = appState.savedDashboardRegistry.dashboard(with: newID),
                  let address = LoginDashboardAddress.refreshed(
                    current: serverUrl, autoFilled: autoFilledURL, dashboardURL: dashboard.normalizedURL)
            else { return }
            fillAddress(address)
        }
        .onReceive(appState.$pendingLoginFailure) { pending in
            // Typed handoff from AppState (rejected saved password,
            // requireSignIn). Unlike an onAppear string read, this fires even
            // when the login card is already mounted; @Published guarantees
            // the current value replays to this new subscriber on mount, so
            // both orderings are covered. Consume once.
            guard let pending else { return }
            failure = pending
            savedRepairAvailable = appState.makeSavedConnectionRepairContext() != nil
            appState.pendingLoginFailure = nil
            refreshSavedSignIn()
        }
        .sheet(item: $connectionSetupDestination) { destination in
            ConnectionSetupView(
                initialDestination: destination,
                initialDraft: ConnectionSetupDraft(existingServerURL: serverUrl, username: username, password: password),
                // The probe may reuse this same-origin service token; the
                // wizard re-verifies the origin itself before sending it and
                // never displays, edits, or persists it.
                initialCloudflareAccess: configuredCloudflareAccess,
                initialCloudflareOriginURL: serverUrl
            ) { result in
                // The tested handoff mapping: clears the in-memory Cloudflare
                // token BEFORE the new address lands whenever the origin
                // changes, so a retained token can never be applied against
                // a dashboard it was not entered for.
                let handoff = LoginCloudflareHandoff.apply(
                    result,
                    to: serverUrl,
                    keeping: LoginCloudflareState(
                        isEnabled: cloudflareEnabled,
                        clientID: cloudflareClientID,
                        clientSecret: cloudflareClientSecret
                    )
                )
                cloudflareEnabled = handoff.cloudflare.isEnabled
                cloudflareClientID = handoff.cloudflare.clientID
                cloudflareClientSecret = handoff.cloudflare.clientSecret
                serverUrl = handoff.serverURL
                username = handoff.username
                password = handoff.password
                failure = nil
                focusedField = nil
            }
        }
        .sheet(item: $connectionRepairContext) { context in
            ConnectionRepairSetupSheet(context: context)
        }
        .sheet(isPresented: $showExtraHeaders) {
            let address = (try? ConnectionURLPolicy.normalizedBaseURL(serverUrl)) ?? serverUrl
            CustomHeadersEditorSheet(
                serverURL: address,
                headers: CustomHeaderStore.shared.headers(forServerURL: address)
            ) { headers in
                CustomHeaderStore.shared.setHeaders(headers, forServerURL: address)
                extraHeadersRevision += 1
            }
        }
        .sheet(isPresented: $showNativeOAuth) {
            NativeOAuthSignInSheet(
                baseURL: nativeOAuthBaseURL,
                cloudflareAccess: configuredCloudflareAccess,
                provider: nativeOAuthProvider,
                dashboardID: nativeOAuthDashboardID,
                onSuccess: { result in
                    Task { @MainActor in
                        failure = nil
                        let baseURL = nativeOAuthBaseURL
                        guard await appState.connectWithNativeOAuth(result, baseURL: baseURL) else {
                            failure = .notice(
                                title: AppLocalization.string("Sign-in failed."),
                                message: AppLocalization.string("Please try again.")
                            )
                            return
                        }
                        if configuredCloudflareAccess == nil {
                            KeychainHelper.clearCloudflareAccess(dashboardID: nativeOAuthDashboardID)
                        }
                    }
                },
                onError: { error in
                    Self.logger.error("Native OAuth sign-in failed: \(String(describing: type(of: error)), privacy: .public)")
                    failure = .notice(
                        title: AppLocalization.string("Sign-in failed."),
                        message: (error as? LocalizedError)?.errorDescription ?? AppLocalization.string("Please try again.")
                    )
                }
            )
        }
        .sheet(isPresented: $showWebView) {
            AuthWebView(
                url: serverUrl,
                cloudflareAccess: configuredCloudflareAccess,
                dashboardIDProvider: { [appState, url = serverUrl] in
                    appState.resolveDashboardID(forURL: url, registerIfMissing: true)
                },
                websiteDataStoreIdentifier: signInWebKitStoreID,
                onTicket: { ticket, baseUrl in
                    // The dashboard is solely an authentication bridge. Dismiss it
                    // before connection work begins so Conduit, not the dashboard,
                    // becomes the active surface as soon as we have a ticket.
                    showWebView = false
                    Task {
                        // OAuth and cloud dashboard logins do not provide a
                        // password credential that Conduit can safely reuse.
                        if let dashboardID = appState.resolveDashboardID(forURL: baseUrl, registerIfMissing: true) {
                            appState.clearSavedPassword(dashboardID: dashboardID)
                            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
                        }
                        appState.rememberDashboardURL(baseUrl)
                        appState.prepareInteractiveSignIn(baseURL: baseUrl)
                        await appState.connect(with: HermesConnection(baseUrl: baseUrl, ticket: ticket))
                    }
                },
                onError: { classifiedFailure, detail in
                    // Fixed classified copy only — the dashboard-provided
                    // detail is logged for diagnosis (default os privacy
                    // redacts it in release builds) and never reaches the
                    // login card.
                    Self.logger.error(
                        "Auth WebView sign-in error: \(String(describing: classifiedFailure), privacy: .public) detail: \(detail)"
                    )
                    // Close the sheet first: a failure under an open sheet is hidden.
                    showWebView = false
                    failure = .presenting(classifiedFailure)
                }
            )
            .asSignInSheet()
        }
    }

    private var loginContent: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 36)

            VStack(spacing: 14) {
                Image(loginIconAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.17 : 0.45), lineWidth: 1)
                    }

                VStack(spacing: 6) {
                    Text("Conduit")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("A focused home for your Hermes work")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Label("Connect a Hermes dashboard", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.conduitAccent)

                // Connection Setup entry point (visible, secondary to
                // Connect, never auto-opened). Round 1 opens the shell;
                // the guided assistant fills it in later.
                Button {
                    connectionSetupDestination = .start
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.body)
                            .foregroundStyle(.conduitAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Need help connecting?")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Set up your Hermes connection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    // The card is the target, not just its text: the padding
                    // and the chevron column are part of the hit region by
                    // declaration rather than by how the label's content
                    // shape happens to be derived.
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("login.connection-setup")

                // Whether the offer shows depends on the connection state, so it is decided here, from state only
                // (the Keychain was read in refreshSavedSignIn()).
                if let savedSignIn,
                   let offer = LoginSavedSignInOffer.make(
                    kind: savedSignIn.kind,
                    biometricKind: biometrics.kind,
                    biometricsAvailable: biometrics.isAvailable,
                    isConnected: appState.isConnected
                   ) {
                    // B5: a cancelled or refused Face ID / Touch ID unlock leaves this card; this is the way to
                    // ask for the saved sign-in again.
                    LoginSavedSignInButton(
                        offer: offer,
                        address: savedSignIn.address,
                        isBusy: isConnecting || appState.isConnecting || isSigningInSaved
                    ) {
                        guard !isSigningInSaved else { return }
                        isSigningInSaved = true
                        Task { @MainActor in
                            await appState.switchDashboard(to: savedSignIn.id)
                            isSigningInSaved = false
                        }
                    }
                }

                TextField("https://hermes.example", text: $serverUrl)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("login.server-url")
                    .focused($focusedField, equals: .server)
                    .submitLabel(LoginField.server.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .onSubmit { handleSubmit(from: .server) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6).frame(minHeight: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.server)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("login.username")
                    .submitLabel(LoginField.username.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .focused($focusedField, equals: .username)
                    .onSubmit { handleSubmit(from: .username) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6).frame(minHeight: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("login.password")
                    .submitLabel(LoginField.password.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .focused($focusedField, equals: .password)
                    .onSubmit { handleSubmit(from: .password) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6).frame(minHeight: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.password)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Save credentials", isOn: $saveCredentials)
                        .tint(.conduitAccent)
                        .onChange(of: saveCredentials) { _, savesCredentials in
                            if !savesCredentials { useFaceID = false }
                        }

                    // Face ID and Touch ID share this one setting; the
                    // wording follows the device's sensor.
                    Toggle(biometricToggleTitle, isOn: $useFaceID)
                        .tint(.conduitAccent)
                        .accessibilityIdentifier("login.biometric-toggle")
                        .disabled(!saveCredentials || !biometrics.isAvailable)

                    // No footnote before the first status read, so a Face ID
                    // phone never flashes "not available".
                    if biometricsLoaded && (!biometrics.isAvailable || saveCredentials) {
                        Text(biometricFootnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use Cloudflare Access service token", isOn: Binding(
                        get: { cloudflareEnabled },
                        set: { enabled in
                            cloudflareEnabled = enabled
                            revealCloudflareSection = enabled
                            // Turning the section off while typing in one of
                            // its fields unmounts them mid-focus; drop focus
                            // explicitly so the keyboard never dangles.
                            if !enabled,
                               focusedField == .cloudflareClientID || focusedField == .cloudflareClientSecret {
                                focusedField = nil
                            }
                        }
                    ))
                    .tint(.conduitAccent)
                    // Stable XCUI handles: the localized label works too, but
                    // identifiers decouple the UI tests from copy changes
                    // and from Switch/CheckBox element-type ambiguity.
                    .accessibilityIdentifier("login.cloudflare-toggle")
                    if cloudflareEnabled {
                        TextField("Cloudflare Client ID", text: $cloudflareClientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("login.cloudflare-client-id")
                            .focused($focusedField, equals: .cloudflareClientID)
                            .submitLabel(LoginField.cloudflareClientID.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                            .onSubmit { handleSubmit(from: .cloudflareClientID) }
                            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 50)
                            .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            .id(LoginField.cloudflareClientID)
                        SecureField("Cloudflare Client Secret", text: $cloudflareClientSecret)
                            .accessibilityIdentifier("login.cloudflare-client-secret")
                            .focused($focusedField, equals: .cloudflareClientSecret)
                            .submitLabel(LoginField.cloudflareClientSecret.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                            .onSubmit { handleSubmit(from: .cloudflareClientSecret) }
                            .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 50)
                            .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            .id(LoginField.cloudflareClientSecret)
                        Text("Used only to reach this Cloudflare-protected dashboard; the secret stays in Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        focusedField = nil
                        showExtraHeaders = true
                    } label: {
                        HStack {
                            Text(AppLocalization.string("Extra headers"))
                            Spacer()
                            let count = extraHeaderCount
                            if count > 0 {
                                Text(verbatim: String(count))
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("login.extra-headers")
                }
                .padding(.horizontal, 2)
                if let failure {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.footnote)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.title)
                                    .font(.footnote.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .accessibilityIdentifier("login.error.title")
                                if !failure.message.isEmpty {
                                    Text(failure.message)
                                        .font(.footnote)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if failure.offersRecoveryActions {
                            AdaptiveStack(spacing: 16) {
                                // A dashboard whose sign-in ended is retried by signing in again (same action).
                                Button(failure.asksToSignInAgain ? AppLocalization.string("Sign In Again") : AppLocalization.string("Try Again")) {
                                    Task { await connect() }
                                }
                                .disabled(isConnecting)
                                .accessibilityIdentifier(failure.asksToSignInAgain ? "login.error.sign-in-again" : "login.error.try-again")

                                if let destination = failure.helpDestination {
                                    Button("Troubleshoot Connection") {
                                        connectionSetupDestination = destination
                                    }
                                    .accessibilityIdentifier("login.error.troubleshoot")
                                }

                                // Round 6: a failed SAVED-credential reconnect
                                // is a failed EXISTING connection — offer the
                                // repair flow seeded from that record. The
                                // typed failure proves provenance (manual
                                // login failures never set it), and entering
                                // repair revokes any outstanding automatic
                                // recovery authority.
                                if savedRepairAvailable, appState.lastConnectionFailure != nil {
                                    Button("Repair Connection") {
                                        connectionRepairContext = appState.beginSavedConnectionRepair()
                                    }
                                    .accessibilityIdentifier("login.repair-connection")
                                }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await connect() }
                } label: {
                    Label(isConnecting ? AppLocalization.string("Connecting…") : AppLocalization.string("Connect"), systemImage: "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 50)
                }
                .accessibilityIdentifier("login.connect")
                .foregroundStyle(.white)
                .disabled(!connectInputsArePresent || isConnecting)
                .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent, prominent: true)
            }
            .padding(20)
            .conduitGlassSurface(cornerRadius: 28, tint: .conduitAccent.opacity(0.07))

            Text("Your credentials stay on this device when you choose to save them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }

    /// URL-presence check shared by the Connect button and connect()'s guard.
    /// Provider discovery decides whether credentials are required.
    private var connectInputsArePresent: Bool {
        Self.hasConnectableInput(serverURL: serverUrl)
    }

    /// URL-only gate: provider discovery decides whether credentials are
    /// required. OAuth-only dashboards must not need dummy username/password.
    static func hasConnectableInput(serverURL: String) -> Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return-key behavior shared by every field: walk the focus chain
    /// (server → username → password → Cloudflare Client ID → Client Secret)
    /// and only submit when the focused field ends the chain. While the
    /// Cloudflare token entry is on, the password field hands focus to the
    /// Cloudflare Client ID instead of triggering Connect.
    private func handleSubmit(from field: LoginField) {
        if let destination = field.submitDestination(cloudflareTokenEntryEnabled: cloudflareEnabled) {
            focusedField = destination
        } else {
            Task { await connect() }
        }
    }

    @MainActor
    private func connect() async {
        // The Connect button is disabled while connecting, but Try Again and
        // the return-key chain also reach this method: never let a second
        // auth sequence run concurrently (Hermes throttles password login).
        guard !isConnecting else { return }
        // A manual login attempt abandons any prior existing-connection
        // failure context: Repair Connection is for the connection that
        // actually failed, not for whatever the user is typing now.
        appState.lastConnectionFailure = nil
        let cleaned = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            // The return-key chain can reach submit without the Connect
            // button ever being enabled (e.g. a whitespace-only URL).
            // Surface the standard invalid-URL feedback instead of a silent
            // no-op.
            failure = .notice(title: AppLocalization.string("Enter a valid dashboard URL."))
            focusedField = .server
            return
        }
        // Preserve WHICH URL-policy rule failed: a malformed address and an
        // insecure remote transport are different mistakes with different
        // fixes, so they classify differently instead of collapsing into one
        // insecure-transport message.
        let normalized: String
        do {
            normalized = try ConnectionURLPolicy.normalizedBaseURL(cleaned)
        } catch {
            // Log the type-safe classification, never the raw error: its
            // associated values can carry server-provided detail text that
            // must not reach the unified log unredacted.
            Self.logger.error("Login URL normalization failed: \(String(describing: ConnectionFailureClassifier.classify(error)), privacy: .public)")
            failure = .presenting(ConnectionFailureClassifier.classify(error))
            return
        }
        serverUrl = normalized
        appState.rememberDashboardURL(serverUrl)
        failure = nil
        isConnecting = true
        defer { isConnecting = false }

        do {
            let access = configuredCloudflareAccess
            let client = NativeAuthClient(baseURL: serverUrl, cloudflareAccess: access)
            let credentialsArePresent = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasTypedCredentials = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var requiresBrowserSignIn = false
            var shouldUseNativeOAuth = false
            var discoveredNativeProvider: String?
            switch try await Self.signInRoute(
                for: client.authProviderDiscovery(),
                hasTypedCredentials: hasTypedCredentials,
                supportsNativeOAuth: { try await client.supportsNativeOAuth() }
            ) {
            case .browser:
                requiresBrowserSignIn = true
            case .nativeOAuth(let provider):
                shouldUseNativeOAuth = true
                discoveredNativeProvider = provider
            case .password:
                break
            }
            if shouldUseNativeOAuth {
                guard let dashboardID = appState.resolveDashboardID(forURL: serverUrl, registerIfMissing: true) else {
                    failure = .notice(title: AppLocalization.string("Could not save this dashboard."))
                    return
                }
                nativeOAuthBaseURL = serverUrl
                nativeOAuthProvider = discoveredNativeProvider
                nativeOAuthDashboardID = dashboardID
                showNativeOAuth = true
                if let access {
                    KeychainHelper.saveCloudflareAccess(access, origin: serverUrl, dashboardID: dashboardID)
                }
                return
            }
            if requiresBrowserSignIn {
                showWebView = true
                // The WebKit session for this sign-in is dashboard-owned:
                // reuse the registered dashboard's identified store when one
                // exists (repair / re-sign-in), otherwise isolate this new
                // sign-in in its own per-presentation store. Never the
                // default store — sibling-host parent-domain cookies must not
                // cross dashboards.
                signInWebKitStoreID = appState.resolveDashboardID(forURL: serverUrl, registerIfMissing: false) ?? UUID()
                // The service token is bound to the dashboard it
                // authenticates; resolve (or pre-register) that dashboard so
                // the scoped write cannot land on another server's record.
                if let access, let dashboardID = appState.resolveDashboardID(forURL: serverUrl, registerIfMissing: true) {
                    KeychainHelper.saveCloudflareAccess(access, origin: serverUrl, dashboardID: dashboardID)
                }
                return
            }

            // Discovery proved this is the password path. Only now require
            // credentials; OAuth-only dashboards reached discovery URL-first.
            guard credentialsArePresent else {
                failure = .notice(title: AppLocalization.string("Enter your dashboard username and password."))
                focusedField = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .username : .password
                return
            }
            let authenticatedConnection = try await client.connect(username: username, password: password)
            let dashboardID = appState.resolveDashboardID(forURL: serverUrl, registerIfMissing: true)
            if let dashboardID {
                if saveCredentials {
                    KeychainHelper.saveCredentials(DashboardCredentials(
                        baseURL: serverUrl,
                        username: username,
                        password: password,
                        requiresFaceID: useFaceID
                    ), dashboardID: dashboardID)
                } else {
                    appState.clearSavedPassword(dashboardID: dashboardID)
                }
                if let access {
                    KeychainHelper.saveCloudflareAccess(access, origin: serverUrl, dashboardID: dashboardID)
                } else {
                    KeychainHelper.clearCloudflareAccess(dashboardID: dashboardID)
                }
                // The next sign-in and the Saved Dashboards rows start with this username.
                appState.rememberDashboardUsername(username, dashboardID: dashboardID)
            }
            if let dashboardID {
                authenticatedConnection.commitCookies(dashboardID: dashboardID)
            }
            appState.prepareInteractiveSignIn(baseURL: serverUrl)
            await appState.connect(with: HermesConnection(baseUrl: serverUrl, ticket: authenticatedConnection.ticket))
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Login connection failed: \(String(describing: ConnectionFailureClassifier.classify(error)), privacy: .public)")
            failure = .presenting(ConnectionFailureClassifier.classify(error))
        }
    }

    /// Puts a dashboard's address in the address field with the Cloudflare token saved for it, and clears a token
    /// that belonged to the previous address.
    private func fillAddress(_ address: String) {
        serverUrl = address
        autoFilledURL = address
        if let access = appState.dashboardScopedCloudflareAccess(for: address) {
            cloudflareEnabled = true
            cloudflareClientID = access.clientID
            cloudflareClientSecret = access.clientSecret
        } else {
            cloudflareEnabled = false
            cloudflareClientID = ""
            cloudflareClientSecret = ""
        }
    }

    private func refreshSavedSignIn() {
        guard let id = appState.activeDashboardID,
              let dashboard = appState.savedDashboardRegistry.dashboard(with: id) else {
            savedSignIn = nil
            return
        }
        // The one Keychain read. The sensor state is the `biometrics` state, read on appear.
        savedSignIn = LoginSavedSignIn(id: id, kind: appState.savedSignIn(for: id), address: dashboard.normalizedURL)
    }

    /// Valid extra headers saved for the address currently typed.
    private var extraHeaderCount: Int {
        _ = extraHeadersRevision
        let address = (try? ConnectionURLPolicy.normalizedBaseURL(serverUrl)) ?? serverUrl
        return CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: address)).count
    }

    var configuredCloudflareAccess: CloudflareAccessCredentials? {
        guard cloudflareEnabled else { return nil }
        return CloudflareAccessCredentials.from(clientID: cloudflareClientID, clientSecret: cloudflareClientSecret)
    }

    private var loginIconAssetName: String {
        switch appState.themePreference {
        case .light:
            return AppIconChoice.light.previewAssetName
        case .dark:
            return AppIconChoice.dark.previewAssetName
        case .system:
            return colorScheme == .dark ? AppIconChoice.dark.previewAssetName : AppIconChoice.light.previewAssetName
        }
    }
}

// MARK: - Setup handoff Cloudflare state

/// The login card's in-memory Cloudflare service-token fields, as a plain
/// value so the setup-wizard handoff decision is unit-testable without
/// hosting the view.
struct LoginCloudflareState: Equatable {
    var isEnabled: Bool
    var clientID: String
    var clientSecret: String
}

enum LoginCloudflareHandoff {
    /// Decides the in-memory Cloudflare token state after the setup wizard
    /// hands back a dashboard address. A retained service token is bound to
    /// the origin it was entered for; when the handoff moves the dashboard to
    /// a different origin (scheme, host, or effective port — path-only
    /// changes are same-origin, per `ConnectionURLPolicy`), the token must
    /// never be silently sent there, so the in-memory state clears. The
    /// persisted Keychain token stays origin-scoped and is deliberately
    /// untouched by this decision.
    static func state(from oldServerURL: String, to newServerURL: String,
                      keeping current: LoginCloudflareState) -> LoginCloudflareState {
        if sameOrigin(oldServerURL, newServerURL) { return current }
        return LoginCloudflareState(isEnabled: false, clientID: "", clientSecret: "")
    }

    static func sameOrigin(_ oldServerURL: String, _ newServerURL: String) -> Bool {
        ConnectionURLPolicy.originMatches(
            URL(string: oldServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            expected: URL(string: newServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// The complete login-field mapping for a wizard handoff, so the view's
    /// completion closure stays a single tested call and a refactor cannot
    /// silently drop the origin check while still assigning the new address.
    static func apply(_ result: ConnectionSetupResult, to oldServerURL: String,
                      keeping cloudflare: LoginCloudflareState)
        -> (serverURL: String, username: String, password: String, cloudflare: LoginCloudflareState) {
        (
            result.serverURL,
            result.username,
            result.password,
            state(from: oldServerURL, to: result.serverURL, keeping: cloudflare)
        )
    }
}

// MARK: - Login field focus chain

/// The login form's focusable fields, in tab order. Internal (not nested in
/// `LoginView`) so the return-key/focus-chain rules are unit-testable without
/// hosting the view.
enum LoginField: Hashable, CaseIterable {
    case server, username, password
    case cloudflareClientID, cloudflareClientSecret

    /// The field the return key should move focus to, or `nil` when return on
    /// this field submits (Connect) instead. While Cloudflare token entry is
    /// enabled, the password field hands focus to the Cloudflare Client ID
    /// rather than triggering Connect, so finishing the dashboard password
    /// can never accidentally submit half-entered Cloudflare credentials.
    func submitDestination(cloudflareTokenEntryEnabled: Bool) -> LoginField? {
        switch self {
        case .server: return .username
        case .username: return .password
        case .password: return cloudflareTokenEntryEnabled ? .cloudflareClientID : nil
        case .cloudflareClientID: return .cloudflareClientSecret
        case .cloudflareClientSecret: return nil
        }
    }

    /// Whether return on this field submits (Connect) instead of advancing
    /// focus. Exposed separately from the keyboard label so the decision
    /// stays unit-testable (SubmitLabel is not Equatable).
    func submits(cloudflareTokenEntryEnabled: Bool) -> Bool {
        submitDestination(cloudflareTokenEntryEnabled: cloudflareTokenEntryEnabled) == nil
    }

    func submitKeyboardLabel(cloudflareTokenEntryEnabled: Bool) -> SubmitLabel {
        submits(cloudflareTokenEntryEnabled: cloudflareTokenEntryEnabled) ? .go : .next
    }
}

// MARK: - Auth WebView navigation policy

/// The authentication WebView's navigation boundary, extracted so the rules
/// are unit-testable without hosting a WKWebView.
///
/// Main frames follow the strict dashboard policy: allowed transport only,
/// unpinned sign-in may traverse the legitimate Cloudflare/IdP redirect
/// chain, and once the dashboard origin pins, top-level navigation cannot
/// escape it. Subframes additionally accept the `about:blank` /
/// `about:srcdoc` documents Cloudflare's Turnstile WebView requirements
/// name. Those documents inherit the parent page's origin, so script inside
/// them could attempt a top-level navigation — but any such attempt
/// re-enters this policy as a MAIN frame navigation, so the allowance never
/// moves the main-frame dashboard-origin boundary.
enum AuthWebViewNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
    }

    static func decide(
        url: URL?,
        isMainFrame: Bool,
        hasPinnedDashboardOrigin: Bool,
        expectedDashboardURL: URL?
    ) -> Decision {
        if !isMainFrame {
            return ConnectionURLPolicy.isAllowedWebViewSubframeTransport(url) ? .allow : .cancel
        }
        guard ConnectionURLPolicy.isAllowedTransport(url) else { return .cancel }
        if !hasPinnedDashboardOrigin {
            // Passwordless/OAuth providers legitimately use a short
            // cross-origin redirect chain during sign-in. The ticket
            // message remains origin-pinned below, and navigation locks
            // to the dashboard as soon as the authenticated route loads.
            return .allow
        }
        guard let expectedDashboardURL,
              ConnectionURLPolicy.originMatches(url, expected: expectedDashboardURL) else {
            return .cancel
        }
        return .allow
    }
}
