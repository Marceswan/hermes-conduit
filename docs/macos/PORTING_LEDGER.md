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
| Conduit/Services/DashboardTicketBridge.swift | R3 | `DashboardTicketBridgeView` is a UIViewRepresentable | ConduitMac/WebViews/WebViewTwins.swift |
| Conduit/Services/NativeOAuth.swift | R3 | `SafariAuthenticationView` presents SFSafariViewController (UIViewControllerRepresentable); also gates `import SafariServices` | ConduitMac/Views/SafariAuthenticationView.swift (opens the default browser via UIApplication.open) |
| Shared/NotificationE2E.swift | R4 | `kSecAttrAccessGroup` for the notification app group; no shared app group on Mac | line omitted on Mac |
| Conduit/Theme.swift | R4 | four `#available(iOS 26.0, *)` glass branches (GlassEffectContainer, glassEffect, glassProminent) need `macOS 26.0` named, else Mac 14 fails to compile | `macOS 26.0` added to the availability list; the pre-26 fallback runs on Mac 14 to 25 |
| Conduit/Intents/StartVoiceConversationIntent.swift | R4 | `supportedModes: IntentModes` is macOS 26 only | `macOS 26.0` added to `@available` |
| Conduit/Intents/AskHermesAboutScreenIntent.swift | R4 | same as StartVoiceConversationIntent | `macOS 26.0` added to `@available` |
| Conduit/Views/Components/SelectableTextView.swift | R2 | UITextView-backed UIViewRepresentable | ConduitMac/Chat/SelectableTextView.swift (real: NSTextView NSViewRepresentable; `selectionCoordinator`/`selectionSegment` accepted and ignored; link clicks go through `Coordinator.textView(_:clickedOnLink:at:)` -> `UIApplication.shared.open` allowlist, R11). `bridge(_:defaultFont:defaultColor:linkColor:)` copied from upstream; keep in sync. `UIFont.withTraits` adapted for NSFontDescriptor (non-optional `withSymbolicTraits`); keep in sync |
| Conduit/Views/Components/ComposerPasteTextView.swift | R2 | UITextView paste override | ConduitMac/Chat/ComposerPasteTextView.swift (placeholder, real in Task 8). Upstream also has `minimumHeight(for:)`/`maximumHeight(for:)` taking a UITraitCollection; no non-test caller, not twinned |
| Conduit/Views/Components/MarkdownSelectionHandles.swift | R2 | iOS cross-block selection handles (UIView) | ConduitMac/Chat/MarkdownSelectionHandles.swift (no-op overlay, locator, chrome root) |
| Conduit/Views/Components/ImagePicker.swift | R2 | UIImagePickerController | ConduitMac/Views/ImagePicker.swift (NSOpenPanel) |
| Conduit/Views/Components/CameraCapture.swift | R2 | UIImagePickerController camera | ConduitMac/Views/CameraCapture.swift (`isAvailable == false`; camera not ported) |
| Conduit/Views/ChatScrollSurfaceLocator.swift | R2 | finds the UIScrollView | ConduitMac/Chat/ChatScrollSurfaceLocator.swift (detached; engine falls back to ScrollViewProxy, real in Task 9) |
| Conduit/Views/SelectionFixtureView.swift | R2 | DEBUG-only iOS selection fixture (UIView.setAnimationsEnabled); only ConduitApp.swift uses it | none needed |
| Conduit/Views/LiquidOrb/LiquidOrbView.swift | R3 | file also declares LiquidOrbPipeline, LiquidOrbState, LiquidOrbRenderer, DevicePowerState, so it stays compiled; only `struct LiquidOrbView` (UIViewRepresentable over MTKView) is gated | ConduitMac/Views/LiquidOrbViewTwin.swift (static placeholder, Plan 3 replaces it). Named `...Twin` because two files with one name in one target make Xcode drop one |
| Conduit/Views/RootView.swift | R3 | `EdgePanGesture` (UIScreenEdgePanGestureRecognizer) | ConduitMac/Views/EdgePanGesture.swift (no-op) |
| Conduit/Views/LoginView.swift | R3 | `AuthWebView` and its Coordinator (WKWebView UIViewRepresentable) | ConduitMac/WebViews/WebViewTwins.swift (real twin; `makeNSView`/`dismantleNSView` renames only, no WebKit API changes) |
| Conduit/Views/Components/MarkdownText.swift | R3 | `MarkdownSelectionHighlightOverlay` + `MarkdownSelectionHighlightView` (UIView), `RemoteImageWebView` (WKWebView). `RemoteImageHTML` stays (private, unused on Mac) | ConduitMac/Views/MarkdownSelectionHighlightOverlay.swift, ConduitMac/WebViews/WebViewTwins.swift (real `RemoteImageWebView` twin; private `RemoteImageHTML` copied as `MacRemoteImageHTML`; was `private`, twin is internal) |
| Conduit/Views/Components/MarkupBlock.swift | R3 | `MarkupWebView`, `SafeMarkupWebView` (WKWebView) | ConduitMac/WebViews/WebViewTwins.swift (real twins; `MarkupWebView` hit-testing off via `PassthroughWebView` since Mac has no `isUserInteractionEnabled`; file-private `MarkupMessageProxy` copied as `MacMarkupMessageProxy`). `SafeMarkupWebView` was `private`; the twin is internal |
| Conduit/Views/Components/MarkdownSelectionCoordinator.swift | R4 (9 regions, `#else` stubs where platform-neutral code calls in) | members that hold or take UITextView/UIWindow/UIScrollView: `SegmentRecord.textView`, register/unregister, `text(for:)`, `copiedAttributedText`, `textLength`, `isSegmentRegistered`, scroll position + `caretRect`, `endSelection` first-responder block, `highlightRects`, and the hit-testing/range block (`endpoint(at:)` ... `selectionRects`) | none: selection is native on Mac. Mac `SegmentRecord.init` takes `Never?` so `replaceSegments` is unchanged. A Mac twin that wants the coordinator must add its own registration |
| Conduit/Views/Components/MediaPreviewPresenter.swift | R4 (3 regions) | QLPreviewController session, `show`/`share`/`topViewController` (UIViewController, UIActivityViewController, connectedScenes), `PreviewItem` | ConduitMac/Views/MediaPreviewPresenterMac.swift (placeholder: quarantines the staged file via FileQuarantine, then reveals it in Finder; QLPreviewPanel later) |
| Conduit/Views/SidebarView.swift | R4 | `EditMode` is unavailable on macOS (`@State editMode` and `.environment(\.editMode, ...)`) | List reorders by drag without it |
| Conduit/Views/Components/ComposerBar.swift | R4-widen | two `#available(iOS 26.0, *)` (GlassEffectContainer, glassEffectID) need `macOS 26.0` named | `macOS 26.0` added to the availability list (R8) |
