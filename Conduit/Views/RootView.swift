//
//  RootView.swift
//  Conduit
//
//  Root container — handles auth state and scene phase changes.
//

import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isPrimaryWindow = false

    var body: some View {
        ZStack {
            // A cold launch that could not reach the server yet still shows
            // the app shell over the read-only saved copy (#99).
            if appState.showLogin
                || (appState.connection == nil && appState.offlineChatPresentation == nil) {
                LoginView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }

            if let bridge = appState.dashboardTicketBridge {
                DashboardTicketBridgeView(bridge: bridge)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showLogin)
        .onChange(of: scenePhase) { _, newPhase in
            // Only the primary window drives the process-wide lifecycle: a
            // transient duplicate window's .background must never suspend a
            // conversation the primary window still presents.
            if isPrimaryWindow {
                appState.handleScenePhase(newPhase)
            }
        }
        .onAppear {
            guard !isPrimaryWindow else { return }
            // Multi-scene support exists for the CarPlay scene; a SECOND
            // foreground Conduit window is not a supported surface and
            // closes itself (the primary window releases its claim on close).
            if ConduitWindowClaimKeeper.claimPrimaryWindow() {
                isPrimaryWindow = true
                appState.startWakeListeningLifecycle()
            } else {
                // Environment-scoped dismissal: close THIS duplicate window
                // only. ID-scoped dismissal targets the WindowGroup and
                // would take the primary window down with it.
                dismissWindow()
            }
        }
        .onDisappear {
            if isPrimaryWindow {
                ConduitWindowClaimKeeper.releaseClaim()
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var prefersPersistentSidebar = false
    @AppStorage(VoiceScreenAwake.preferenceKey) private var keepScreenAwake = false
    @State private var availableWindowWidth: CGFloat = 0
    @State private var settingsPresentation: SettingsSnapshot?
    @State private var shouldPresentSettingsAfterSidebarDismissal = false
    /// The page Settings opens at next, for an in-app settings link.
    @State private var settingsOpensAt: ConduitAppLink.SettingsLink?
    @State private var chatTitlePendingRename: SessionSummary?
    @State private var chatTitlePendingDeletion: SessionSummary?

    private var sidebarPresentation: SidebarPresentation {
        #if os(macOS) // MAC: always the split view; no drawer, no first-frame flash
        return .persistent
        #else // MAC:
        return SidebarLayoutPolicy.resolvePresentation(
            idiom: UIDevice.current.userInterfaceIdiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWindowWidth
        )
        #endif // MAC:
    }

    private var isPersistentSidebarActive: Bool { sidebarPresentation == .persistent }

    #if os(macOS) // MAC: route-aware chat chrome (D6): a chat hidden under Bots/Cron/Kanban adds no toolbar items, title or backdrop motion
    @AppStorage(MacSidebarState.tabDefaultsKey) private var macTabRaw = SidebarTab.sessions.rawValue
    private var chatPaneActive: Bool { MacChatRoute.isChatActive(tabRaw: macTabRaw) }
    private var chatWindowTitle: String { MacChatRoute.navigationTitle(tabRaw: macTabRaw) }
    #endif // MAC:

    var body: some View {
        sidebarLayoutContent
        // Changes Hermes asked for or just made (AgentSettings.swift).
        .overlay(alignment: .top) {
            AgentSettingsBanner(sync: appState.agentSettings)
        }
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showContextSheet) {
            ContextSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showWorkspaceSheet) {
            WorkspaceBrowserSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGatewaySheet) {
            GatewayDiagnosticsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showAgentsSheet) {
            DelegateAgentsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // "Keep phone awake during voice conversations": hold off auto-lock
        // only while a voice conversation is on screen.
        .onChange(
            of: VoiceScreenAwake.holdsScreenAwake(
                enabled: keepScreenAwake,
                voiceSheetShown: appState.showVoiceSheet,
                liveSheetShown: appState.showGeminiLiveSheet || appState.showGPTLiveSheet || appState.showGrokLiveSheet
            ),
            initial: true
        ) { _, holds in
            UIApplication.shared.isIdleTimerDisabled = holds
        }
        // Sign-out swaps this view out with a sheet possibly still up.
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Swiping a running call away minimises it; End hangs up.
        .sheet(isPresented: $appState.showGeminiLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.geminiLive) }) {
            GeminiLiveVoiceSheet(
                controller: appState.geminiLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                onClose: appState.closeGeminiLiveConversation,
                onRetry: { Task { await appState.geminiLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { voiceScreenshotBanner }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGrokLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.grokLive) }) {
            GeminiLiveVoiceSheet(
                controller: appState.grokLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                engine: .grok,
                onClose: appState.closeGrokLiveConversation,
                onRetry: { Task { await appState.grokLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { voiceScreenshotBanner }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGPTLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.gptLive) }) {
            GPTLiveVoiceSheet(
                controller: appState.gptLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                onClose: appState.closeGPTLiveConversation,
                onRetry: { Task { await appState.gptLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { voiceScreenshotBanner }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showVoiceSheet, onDismiss: appState.closeVoiceConversation) {
            VoiceConversationSheet(
                controller: appState.voiceConversationController,
                backgroundJobs: appState.voiceBackgroundJobSupervisor,
                profile: appState.activeProfile,
                onClose: appState.closeVoiceConversation,
                shouldAutoListen: { appState.consumeVoiceSheetAutoListenIfPresenting() }
            )
                .safeAreaInset(edge: .top, spacing: 0) { voiceScreenshotBanner }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $settingsPresentation, onDismiss: {
            appState.isSettingsSheetPresented = false
            Task { await appState.refreshVoiceCapabilities() }
        }) { snapshot in
            SettingsView(
                snapshot: snapshot,
                saveTheme: { appState.themePreference = $0 },
                persistBusyInputMode: { mode in await appState.setBusyInputMode(mode) },
                persistChatResumeBehavior: { appState.setChatResumeBehavior($0) },
                persistChatReturnSurface: { appState.setChatReturnSurface($0) },
                loadProfileSettings: { keys in await appState.loadProfileSettings(keys: keys) },
                persistProfileSetting: { key, value in await appState.setProfileSetting(key, value: value) },
                loadProfileConfigOptions: { await appState.loadProfileConfigOptions() },
                loadProfileModelDefaults: { await appState.loadProfileModelDefaults() },
                persistProfileMainModel: { provider, model, reasoning in
                    await appState.setProfileMainModel(provider: provider, model: model, reasoning: reasoning)
                },
                saveDefaultProfileName: { appState.saveDefaultProfileName($0) },
                reconnect: {
                    await appState.reconnect()
                    return appState.isConnected
                },
                disconnect: { appState.disconnect() }
            )
                .presentationDetents([.large])
        }
        // Settings can go with this screen (switching or adding a dashboard
        // swaps in sign-in), and SwiftUI doesn't promise the sheet's
        // onDismiss then. Its flag must not outlive it: it holds back the
        // return surface while it claims a sheet is up.
        .onDisappear { appState.isSettingsSheetPresented = false }
        .background(windowWidthReader)
        .onPreferenceChange(MainViewWindowWidthKey.self) { availableWindowWidth = $0 }
        .onChange(of: isPersistentSidebarActive) { _, persistentActive in
            // Hard invariant: the persistent layout must never coexist with
            // showSidebar == true — that flag suppresses streaming/reasoning
            // publication. A resize, rotation, or the Appearance toggle can
            // activate the persistent layout while the drawer is presented.
            if persistentActive { appState.dismissSidebarDrawer() }
        }
        .task(id: voiceCapabilityRefreshKey) {
            await appState.refreshVoiceCapabilities()
        }
        // Cold launch: MainView first becoming the authenticated surface is
        // the qualifying return. The hook fires once per process (re-login
        // cycles rely on the scene-phase path instead), then any pending
        // request — including one from scene activation — is consumed.
        .task {
            appState.requestPreferredReturnSurfaceForColdLaunch()
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.preferredReturnSurfaceRequest) { _, _ in
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.settingsLinkRequest) { _, page in
            guard let page else { return }
            appState.settingsLinkRequest = nil
            openSettings(at: page)
        }
        #if os(macOS) // MAC: the command palette opens Settings (D18)
        .onReceive(NotificationCenter.default.publisher(for: .macOpenSettingsRequested)) { _ in
            guard settingsPresentation == nil else { return }
            settingsOpensAt = nil
            if appState.showSidebar, !isPersistentSidebarActive {
                presentSettingsFromDrawer()
            } else {
                presentSettings()
            }
        }
        #endif // MAC:
    }

    /// An in-app settings link (`conduit://settings/calls` or `/voice`, in a reply):
    /// Settings opens at that page. Settings already open stays as it is,
    /// and so does a voice or other sheet: closing a voice sheet ends its
    /// call, and only one sheet shows at a time.
    private func openSettings(at page: ConduitAppLink.SettingsLink) {
        guard settingsPresentation == nil else { return }
        let otherSheetUp = appState.showModelPicker || appState.showContextSheet || appState.showWorkspaceSheet
            || appState.showGatewaySheet || appState.showAgentsSheet || appState.showVoiceSheet
            || appState.showGeminiLiveSheet || appState.showGrokLiveSheet || appState.showGPTLiveSheet
        guard !otherSheetUp else { return }
        // A host without calls (or not heard from yet) has no such page:
        // Settings opens at its start.
        switch page {
        case .calls: settingsOpensAt = appState.supportsHermesCalls ? page : nil
        case .voice: settingsOpensAt = page
        }
        if appState.showSidebar, !isPersistentSidebarActive {
            presentSettingsFromDrawer()
        } else {
            presentSettings()
        }
    }

    /// Ask Hermes About Screen: the screenshot the voice will ask about.
    private var voiceScreenshotBanner: some View {
        ScreenQuestionVoiceBanner(
            screenshot: appState.voiceScreenshot,
            onDiscard: appState.discardVoiceScreenshot,
            onNewChat: appState.canMoveVoiceScreenshotToNewChat
                ? { Task { await appState.moveVoiceScreenshotToNewChat() } }
                : nil
        )
    }

    /// Routes the sidebar between its two presentations: the existing chat
    /// shell with the modal drawer, or — on wide iPad windows with the
    /// Appearance opt-in — the same SidebarView as a persistent leading
    /// column beside the chat.
    @ViewBuilder
    private var sidebarLayoutContent: some View {
        if isPersistentSidebarActive {
            #if os(macOS) // MAC: native resizable split view (D6)
            MacSplitLayout(
                sidebar: {
                    SidebarView(
                        onRequestSettings: presentSettingsFromPersistentSidebar,
                        presentation: .persistent
                    )
                },
                chat: { chatNavigationContent }
            )
            #else // MAC:
            HStack(spacing: 0) {
                SidebarView(
                    onRequestSettings: presentSettingsFromPersistentSidebar,
                    presentation: .persistent
                )
                .frame(width: SidebarLayoutMetrics.persistentSidebarWidth)

                Divider()
                    .ignoresSafeArea(.container, edges: .vertical)

                chatNavigationContent
            }
            #endif // MAC:
        } else {
            chatNavigationContent
        }
    }

    /// The chat shell's window-toolbar items (moved out of `chatNavigationContent`
    /// so the Mac route gate can wrap them without touching the iOS call).
    @ToolbarContentBuilder
    private var chatToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // An open room supplies its own leading Leave button; a
            // second leading control would be ambiguous. The edge
            // swipe still opens the sidebar.
            if !isPersistentSidebarActive && appState.activeRoomSurface == nil {
                Button {
                    appState.showSidebar = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                .accessibilityLabel("Open sessions")
            }
        }
        // Session-only controls: an open room owns the title and
        // actions (GroupChatView's toolbar), so the session's title,
        // scroll-to-top, and refresh must not act on the hidden
        // conversation behind it.
        if appState.activeRoomSurface == nil {
            ToolbarItem(placement: .principal) {
                #if os(macOS) // MAC: session tabs replace the title pill (D11)
                MacSessionTabStrip(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 }
                )
                #else // MAC:
                ChatTitleControl(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 }
                )
                #endif // MAC:
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await appState.refreshActiveSession() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .rotationEffect(.degrees(appState.isChatRefreshing ? 360 : 0))
                        .animation(
                            appState.isChatRefreshing
                                ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                                : .default,
                            value: appState.isChatRefreshing
                        )
                        #if os(iOS) // MAC: the system toolbar platter sizes the item (D7)
                        .frame(width: 40, height: 40)
                        #endif // MAC:
                }
                #if os(iOS) // MAC: no second glass layer over the system platter (D7)
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                #endif // MAC:
                .disabled(!appState.isConnected || appState.isChatRefreshing)
                .accessibilityLabel("Refresh conversation")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            ConnectionStatusIndicator()
        }
    }

    /// The existing chat shell, shared by both sidebar layouts so the drawer
    /// and the persistent column render the identical conversation surface.
    /// Only the drawer affordances (hamburger and left-edge swipe) hide while
    /// the persistent sidebar is visible. An open Group Chat room replaces
    /// the conversation surface wholesale: a room is NOT a session, so this
    /// swap is the entire viewport integration — `ChatView`'s session state
    /// (and the saved `SessionReference`) is untouched by room navigation.
    private var chatNavigationContent: some View {
        NavigationStack {
            ZStack {
                #if os(macOS) // MAC: paused while the chat is hidden
                ConduitBackdrop(drifts: chatPaneActive)
                #else // MAC:
                ConduitBackdrop(drifts: true)
                #endif // MAC:
                if appState.activeRoomSurface != nil {
                    // Keyed by room: another room starts with its own draft.
                    GroupChatView()
                        .id(appState.activeRoomSurface?.room.roomID)
                } else {
                    ChatView()
                }
            }
            .overlay(alignment: .leading) {
                if !isPersistentSidebarActive {
                    EdgePanGesture { appState.showSidebar = true }
                        .frame(width: 25)
                        .ignoresSafeArea()
                }
            }
            #if os(macOS) // MAC: pane name while chat is hidden, so this stack cannot override the router's title
            .navigationTitle(chatWindowTitle)
            .macHidingToolbarTitle(MacChatRoute.hidesToolbarTitle(tabRaw: macTabRaw)) // MAC: the pane header names the pane; keep the title string, hide it from the toolbar
            #else // MAC:
            .navigationTitle("")
            #endif // MAC:
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #if os(macOS) // MAC: no chat toolbar items while another pane is shown (D6); the filler keeps the window search item trailing now the pane title is hidden
            .toolbar { if chatPaneActive { chatToolbarContent } else { MacPaneToolbarFill() } }
            #else // MAC:
            .toolbar { chatToolbarContent }
            #endif // MAC:
        }
        // The chat title's menu needs host-owned rename and delete prompts,
        // like the session list's rows.
        .sheet(item: $chatTitlePendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task { await appState.renameSession(session, to: title) }
            }
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { chatTitlePendingDeletion != nil },
            set: { if !$0 { chatTitlePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = chatTitlePendingDeletion else { return }
                chatTitlePendingDeletion = nil
                Task { await appState.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { chatTitlePendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .sheet(isPresented: $appState.showSidebar, onDismiss: presentSettingsAfterSidebarDismissal) {
            SidebarView(onRequestSettings: presentSettingsFromDrawer)
                .environmentObject(appState)
                .presentationDetents([.large])
                .transaction { transaction in
                    transaction.animation = .easeInOut(duration: 0.15)
                }
        }
    }

    private func presentSettingsFromDrawer() {
        shouldPresentSettingsAfterSidebarDismissal = true
        appState.showSidebar = false
    }

    /// Persistent mode keeps the sidebar visible, so Settings opens directly
    /// instead of waiting for the drawer sheet to dismiss first.
    private func presentSettingsFromPersistentSidebar() {
        presentSettings()
    }

    private func presentSettingsAfterSidebarDismissal() {
        guard shouldPresentSettingsAfterSidebarDismissal else {
            // A link's page belongs to the Settings it opened, not a later one.
            settingsOpensAt = nil
            return
        }
        shouldPresentSettingsAfterSidebarDismissal = false
        presentSettings()
    }

    private func presentSettings() {
        appState.isSettingsSheetPresented = true
        var snapshot = appState.makeSettingsSnapshot()
        snapshot.opensAt = settingsOpensAt
        settingsOpensAt = nil
        settingsPresentation = snapshot
    }

    /// Presents the sessions drawer for a preferred-return-surface request.
    /// Consumption semantics (defer-while-pending, claim-once-per-request,
    /// drop on precedence losers) live in AppState so they survive MainView
    /// teardown; this layer only owns the actual sheet presentation. An
    /// active persistent sidebar already shows Sessions, so the request is
    /// consumed without opening a redundant drawer.
    private func presentPreferredReturnSurfaceIfNeeded() {
        guard appState.claimPreferredReturnSurfacePresentation() else { return }
        guard SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
            persistentSidebarActive: isPersistentSidebarActive,
            drawerPresented: appState.showSidebar
        ) else { return }
        appState.showSidebar = true
    }

    private var windowWidthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MainViewWindowWidthKey.self, value: proxy.size.width)
        }
    }

    private var voiceCapabilityRefreshKey: String {
        "\(appState.isConnected):\(appState.activeProfile)"
    }
}

/// Reports the width of the window hosting MainView so the sidebar layout
/// decision tracks Split View, Stage Manager, and window resizing.
private struct MainViewWindowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Chat Title

/// The open chat's title. A tap scrolls to the top of the conversation;
/// touch and hold opens the session list's actions for this chat (Rename,
/// Pin, Move to Project, Archive, Delete), so it can be fixed without
/// leaving the chat (#446), cron runs included (#512). A chat without a row of
/// its own (a new chat, a Bot Chat, an offline copy) keeps the plain tap-only
/// title.
private struct ChatTitleControl: View {
    @EnvironmentObject var appState: AppState
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void

    var body: some View {
        if let session = appState.activeChatSessionSummary {
            Menu {
                SessionActionMenuItems(
                    session: session,
                    onRename: { onRename(session) },
                    onDelete: { onDelete(session) }
                )
            } label: {
                titleLabel
            } primaryAction: {
                appState.requestChatScrollToTop()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            // No large content viewer here: its touch and hold would take
            // the one that opens the conversation actions.
            .accessibilityLabel(appState.displayedChatTitle)
            .accessibilityHint(AppLocalization.string("Scroll to top of conversation. Touch and hold for conversation actions."))
            // VoiceOver may open the menu on activation; the scroll stays
            // reachable as a named action.
            .accessibilityAction(named: Text(AppLocalization.string("Scroll to top of conversation"))) {
                appState.requestChatScrollToTop()
            }
        } else {
            Button {
                appState.requestChatScrollToTop()
            } label: {
                titleLabel
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer { Text(appState.displayedChatTitle) }
            .accessibilityLabel(appState.displayedChatTitle)
            .accessibilityHint(AppLocalization.string("Scroll to top of conversation"))
        }
    }

    private var titleLabel: some View {
        Text(appState.displayedChatTitle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            #if os(macOS) // MAC: flat pill on the system toolbar platter, standard item height (D7)
            .macToolbarTitlePill()
            #else // MAC:
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.06))
            #endif // MAC:
            // The navigation bar doesn't grow; touch and hold shows it large.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

// MARK: - Connection Status

struct ConnectionStatusIndicator: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState

    private var color: Color {
        if appState.isConnected {
            return .green
        } else if appState.isConnecting {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        Button {
            Task { await appState.loadGatewayDiagnostics() }
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.75), radius: appState.isConnected ? 5 : 0)
                Circle()
                    .stroke(color.opacity(0.38), lineWidth: 1)
                    .frame(width: 19, height: 19)
            }
            #if os(iOS) // MAC: the system toolbar platter sizes the item (D7)
            .frame(width: 40, height: 40)
            #endif // MAC:
        }
        #if os(iOS) // MAC: no second glass layer over the system platter (D7)
        .conduitGlassControl(cornerRadius: 20, tint: color.opacity(0.10))
        #endif // MAC:
        .animation(ConduitMotion.response, value: appState.isConnected)
        .accessibilityLabel(appState.isConnected ? AppLocalization.string("Gateway connected") : AppLocalization.string("Gateway disconnected"))
    }
}


// MARK: - Edge Pan Gesture

#if os(iOS) // MAC: Mac twin in ConduitMac/Views/EdgePanGesture.swift
/// Detects a left-edge pan gesture to open the sidebar.
/// Uses UIScreenEdgePanGestureRecognizer (~20pt edge width) via UIViewRepresentable.
struct EdgePanGesture: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(context.coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
#endif // MAC:
