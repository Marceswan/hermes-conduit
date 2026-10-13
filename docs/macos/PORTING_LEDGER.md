# macOS porting ledger

Every upstream file the Mac target excludes, gates, or twins. Re-check this
list after each `git merge upstream/main`.

| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/CarPlay/CarPlayVoiceSceneDelegate.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceCoordinator.swift | R2 | imports CarPlay | ConduitMac/Stubs/CarPlayStubs.swift |
| Conduit/CarPlay/CarPlayBrowseTemplates.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceTemplateFactory.swift | R2 | imports CarPlay | CarPlayVoiceControls copied to CarPlayStubs.swift |
| Conduit/CarPlay/PhoneScenePresence.swift | R2 | UIScene foreground check | ConduitMac/Stubs/PhoneScenePresence.swift |
| Conduit/Watch/WatchVoiceLink.swift | R2 | imports WatchConnectivity | ConduitMac/Stubs/WatchVoiceLinkStub.swift |
| Conduit/Voice/HermesNativeCalls.swift | R3 | CallKit/PushKit class | ConduitMac/Stubs/HermesNativeCallsStub.swift |
| Conduit/CarPlay/CarPlayVoiceArtwork.swift | R2 | UIGraphicsImageRenderer drawing, used only by the excluded CarPlay files | none needed |
| Conduit/Services/DashboardTicketBridge.swift | R3 | `DashboardTicketBridgeView` is a UIViewRepresentable | ConduitMac/Twins/DashboardTicketBridgeView.swift |
| Conduit/Services/NativeOAuth.swift | R3 | `SafariAuthenticationView` presents SFSafariViewController (UIViewControllerRepresentable); also gates `import SafariServices` | ConduitMac/Twins/SafariAuthenticationView.swift (opens the default browser via UIApplication.open) |
| Shared/NotificationE2E.swift | R4 | `kSecAttrAccessGroup` for the notification app group; no shared app group on Mac | line omitted on Mac |
| Conduit/Theme.swift | R4 | four `#available(iOS 26.0, *)` glass branches (GlassEffectContainer, glassEffect, glassProminent) need `macOS 26.0` named, else Mac 14 fails to compile | `macOS 26.0` added to the availability list; the pre-26 fallback runs on Mac 14 to 25 |
| Conduit/Intents/StartVoiceConversationIntent.swift | R4 | `supportedModes: IntentModes` is macOS 26 only | `macOS 26.0` added to `@available` |
| Conduit/Intents/AskHermesAboutScreenIntent.swift | R4 | same as StartVoiceConversationIntent | `macOS 26.0` added to `@available` |
