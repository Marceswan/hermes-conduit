import SwiftUI

/// The link policy for the Mac root view (R11). Mirrors ConduitApp.swift's
/// `openURL` handler, except that a link leaves the app only when
/// `UIApplication.allowsExternalOpen` allows it (web, mail, System Settings).
enum MacOpenURLPolicy {
    enum Decision: Equatable {
        case handled, systemAction, discarded

        var result: OpenURLAction.Result {
            switch self {
            case .handled: return .handled
            case .systemAction: return .systemAction
            case .discarded: return .discarded
            }
        }
    }

    @MainActor
    static func decision(
        for url: URL,
        routeWidgetLaunch: (URL) -> Bool,
        openAppLink: @escaping @MainActor (ConduitAppLink) -> Void
    ) -> Decision {
        if routeWidgetLaunch(url) { return .handled }
        guard let link = ConduitAppLink(url: url) else {
            // The scheme is registered, so the system would hand a conduit
            // link Conduit can't read straight back to it.
            if url.scheme?.lowercased() == ConduitAppLink.scheme { return .discarded }
            return UIApplication.allowsExternalOpen(url) ? .systemAction : .discarded
        }
        Task { @MainActor in openAppLink(link) }
        return .handled
    }
}

extension View {
    /// The one link policy of every Conduit scene (R11): in-app links route to the
    /// app, everything else passes the scheme allowlist. A scene without it would
    /// hand gateway-controlled markdown links to SwiftUI's default action.
    @MainActor
    func macLinkPolicy(routeWidgetLaunch: @escaping (URL) -> Bool,
                       openAppLink: @escaping @MainActor (ConduitAppLink) -> Void) -> some View {
        environment(\.openURL, OpenURLAction { url in
            MacOpenURLPolicy.decision(for: url, routeWidgetLaunch: routeWidgetLaunch, openAppLink: openAppLink).result
        })
    }

    @MainActor
    func macLinkPolicy(appState: AppState) -> some View {
        macLinkPolicy(routeWidgetLaunch: { appState.routeWidgetLaunchURL($0) },
                      openAppLink: { appState.openAppLink($0) })
    }
}

@main
struct ConduitMacApp: App {
    @NSApplicationDelegateAdaptor(ConduitMacAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var pendingVoiceIntents = PendingVoiceIntentStore.shared
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// A chat another app asked to open (`conduit://session/<id>`), held
    /// until Hermes is connected.
    @State private var pendingExternalLink: ConduitAppLink?

    init() {
        MacDefaults.register()
        if !MacDefaults.isRunningUnderXCTest {
            SheetEscape.install()
            SheetCloseButton.install()
        }
    }

    var body: some Scene {
        WindowGroup("Conduit", id: "conduit-primary") {
            rootContent
                .frame(minWidth: MacSidebarState.windowMinWidth, minHeight: 560)
                .modifier(MacRegisterPrimaryWindowOpener())
        }
        .defaultSize(width: 1180, height: 780)
        .commands { ConduitCommands(appState: appState, tabs: .shared, notch: .shared, palette: .shared, updater: .shared, quickAsk: .shared) }
        // A popped-out session (D21). Not `.commands`: the menu bar is the main scene's.
        WindowGroup("Conduit Chat", id: MacSessionWindows.sceneID, for: MacSessionWindowToken.self) { $token in
            MacSessionWindowScene(token: token)
        }
        .defaultSize(width: 640, height: 760)
        // A conduit:// open (D25) must never create a token-less session window: the main window
        // claims external events (`rootContent`), this scene claims none.
        .handlesExternalEvents(matching: [])
    }

    // Ported from ConduitApp.swift; keep in sync. Skipped: see docs/macos/PORTING_LEDGER.md.
    private var rootContent: some View {
        RootView()
            // Cmd-K palette (D18): over the whole root view, so a sheet covers it.
            .overlay { MacPaletteView() }
            .environmentObject(appState)
            // Whole-chat find (D23): this window's controller, in the environment.
            .macChatFind(appState: appState)
            .task { MacSessionTabsStore.shared.bind(to: appState) }
            .task(id: appState.isConnected) { NotchStatusController.shared.bind(to: appState) }   // no-op once bound; the feed is created by the shared base's bootstrap
            .macSpotlightBinding(appState: appState, openLink: { pendingExternalLink = $0 })
            .task { MacPaletteStore.shared.bind(to: appState) }
            .environment(\.locale, appLanguage.resolvedLocale)
            .onChange(of: appLanguage.selection) { _, _ in
                appState.appLanguageDidChange()
                appState.publishWidgetLanguage()   // D25: ported from ConduitApp.swift
                MacNotificationRuntime.shared.languageDidChange()
            }
            .preferredColorScheme(appState.themePreference.colorScheme)
            // The tint and the accent environment (#697, #702, #750): a new pick redraws at once.
            .macAccentEnvironment()
            // Cmd-Shift-D saved-dashboards sheet (D22): after the environment and tint it inherits.
            .macDashboardSwitcher(appState: appState)
            // Chat > Artifacts... sheet (Task 13).
            .macChatArtifactsSheet(appState: appState)
            // Links Conduit writes into chats (a voice call's job link)
            // open inside the app; every other link goes to the system.
            .macLinkPolicy(appState: appState)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            // Another app opening a chat: only session links, opened through
            // the same route as an in-app link once Hermes is connected.
            .onOpenURL { url in
                if appState.routeWidgetLaunchURL(url) { return }
                guard let link = ConduitAppLink(externalURL: url) else { return }
                pendingExternalLink = link
            }
            .task(id: externalLinkRouteKey) {
                guard appState.isConnected, let link = pendingExternalLink else { return }
                pendingExternalLink = nil
                appState.openAppLink(link)
            }
            .macServiceRouting(appState: appState)
            .macIntentRouting(appState: appState)
            .task { SiriProfileShortcuts.refresh() }
            .task(id: voiceIntentRouteKey) {
                while await resolvePendingVoiceIntent() {
                    do { try await Task.sleep(for: Self.settleRecheckInterval) } catch { return }
                }
            }
            .task(id: voiceIntentDeadlineKey) {
                await waitOutPendingVoiceDeadline()
            }
            .task(id: parkedScreenQuestionKey) {
                appState.scheduleParkedScreenQuestionResume(recheck: Self.settleRecheckInterval)
            }
    }

    /// How often a screenshot waiting for Conduit to settle checks again.
    private static let settleRecheckInterval: Duration = .milliseconds(250)

    private var parkedScreenQuestionKey: String {
        "\(appState.isConnected):\(appState.isConnecting):\(appState.isProfileSwitching):\(appState.parkedScreenQuestionRevision)"
    }

    private var externalLinkRouteKey: String {
        "\(pendingExternalLink?.url.absoluteString ?? "none"):\(appState.isConnected)"
    }

    private var voiceIntentRouteKey: String {
        let connection = appState.voiceLaunchConnectionSnapshot()
        // Phase (not a bare isConnected flag) so connecting → stableFailure
        // re-evaluates the pending request while remaining disconnected.
        // Do not embed pendingSource: take() clears it without a revision
        // bump, and openVoiceConversation’s @Published mutations would flip
        // the key mid-handler and cancel the in-flight route task.
        return "\(pendingVoiceIntents.revision):\(connection.phase.rawValue)"
    }

    /// Deadline changes (new Siri enqueue / supersede) re-arm the wait; the
    /// revision already covers every other store mutation.
    private var voiceIntentDeadlineKey: String {
        guard let deadline = pendingVoiceIntents.pendingExternalLaunchDeadline else { return "none" }
        return "\(pendingVoiceIntents.revision):\(Int(deadline.timeIntervalSinceReferenceDate))"
    }

    /// Resolves the pending voice launch once. Ownership token: only the
    /// claimed request may be routed or failed; a superseded completion is
    /// discarded without publishing. Returns true when a screenshot is
    /// left waiting for Conduit to settle.
    private func resolvePendingVoiceIntent() async -> Bool {
        let router = PendingVoiceIntentRouter(store: pendingVoiceIntents)
        let connection = appState.voiceLaunchConnectionSnapshot()
        // The router takes this exact request first, before it awaits.
        let routed = pendingVoiceIntents.peekClaim()?.intent
        var screenQuestionOpened: Bool?
        let outcome = await router.routePending(connection: connection) { intent in
            if intent.source == .screenQuestion {
                let opened = await appState.openScreenQuestion(intent)
                screenQuestionOpened = opened
                return opened
            }
            return await appState.openVoiceConversation(intent)
        }
        switch outcome {
        case .failed(let message):
            // A screenshot is kept when Hermes can't be reached: it is
            // attached once Hermes connects and Conduit settles.
            let request = routed?.screenQuestion
            if let request {
                appState.parkScreenQuestion(request, profile: routed?.profile)
            }
            // Past its deadline while connected but still settling, Hermes
            // was reached: the screenshot waits without the banner.
            if request == nil || !appState.isConnected {
                appState.errorMessage = message
            }
        case .superseded:
            // A newer request took over while this one found Hermes gone.
            if screenQuestionOpened == false, let request = routed?.screenQuestion {
                appState.settleSupersededScreenQuestion(
                    request,
                    profile: routed?.profile,
                    newerScreenQuestionPending: pendingVoiceIntents.peekClaim()?.intent.screenQuestion != nil
                )
            }
        case .deferred:
            return routed?.screenQuestion != nil && connection.isSettling
        case .idle, .routed:
            break
        }
        return false
    }

    /// Authoritative 30s backstop. Sleeps on the monotonic clock, then
    /// expires the exact claim that armed the wait — never routes through
    /// generic readiness (which could return `.waiting` again).
    private func waitOutPendingVoiceDeadline() async {
        guard let claim = pendingVoiceIntents.peekClaim(),
              let elapsedDeadline = claim.intent.externalLaunchElapsedDeadline else {
            return
        }
        let now = ContinuousClock.now
        if now < elapsedDeadline {
            do {
                try await Task.sleep(for: now.duration(to: elapsedDeadline))
            } catch {
                // Superseded/cancelled waiter must not resolve a different intent.
                return
            }
        }
        guard let expired = pendingVoiceIntents.expireClaimIfCurrent(claim) else {
            return
        }
        if expired.source == .siri {
            appState.errorMessage = PendingVoiceLaunchPolicy.expiredFailureMessage
        } else if let request = expired.screenQuestion {
            appState.parkScreenQuestion(request, profile: expired.profile)
            // Connected but still settling, Hermes was reached: the
            // screenshot is attached once Conduit settles.
            if !appState.isConnected {
                appState.errorMessage = PendingVoiceLaunchPolicy.screenQuestionFailureMessage
            }
        }
    }
}
