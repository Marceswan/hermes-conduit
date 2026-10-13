# macOS port decisions

## D1: UIKit module packaging (Task 1 spike, 2026-10-13)
Result: module named UIKit works, provided the framework product is also named UIKit (PRODUCT_NAME: UIKit, PRODUCT_MODULE_NAME: UIKit). No fallback needed.
Evidence: with PRODUCT_NAME: ConduitUIKitCompat the build failed with
`ProbeApp.swift:2:8: error: Unable to resolve module dependency: 'UIKit'`
(Swift locates a framework module by framework directory name, UIKit.framework, not by module name). After setting PRODUCT_NAME: UIKit: `** BUILD SUCCEEDED **`; Debug products contain UIKit.framework; the app launched (pgrep -x Conduit returned a pid).

## D2: AVAudioSession shadowing (Task 1 spike, 2026-10-13)
Result: same-named class in app target shadows AVFAudio
Evidence: probe declared `final class AVAudioSession` in the app module alongside `import AVFAudio`; no ambiguity error, `** BUILD SUCCEEDED **`.

## D3: SwiftUI-only upstream files and the UIKit module (Task 6, 2026-10-13)
Result: ConduitMac builds with `OTHER_SWIFT_FLAGS = -Xfrontend -import-module -Xfrontend UIKit`, so the shim module is visible in every file. Upstream view files that `import SwiftUI` only (iOS SwiftUI re-exports UIKit) then resolve UIImage, UIPasteboard, UIKeyboardType, UIUserInterfaceIdiom and the rest without an upstream `import UIKit` line.
Evidence: before the flag, errors such as `cannot find type 'UIImage' in scope` in BotEditorSheet.swift, ProfilePickerSheet.swift, ChatSupportSheets.swift, SidebarLayout.swift; after: gone, no upstream edit.
Two side effects, both handled in project.yml:
- The SDK has a cross-import overlay for AppIntents + a module named UIKit (`_AppIntents_UIKit`). macOS has none, so every file importing AppIntents failed with `no such module '_AppIntents_UIKit'`. Fix: an empty framework target `AppIntentsUIKitOverlay` (PRODUCT_NAME `_AppIntents_UIKit`), sources in ConduitMac/Compat/Overlay.
- Explicit module builds cannot see the SDK cross-import overlays (`no such module '_AppIntents_AppKit'`), so `SWIFT_ENABLE_EXPLICIT_MODULES: NO` on ConduitMac. Removing it reproduces the error.

## D4: iOS-only SwiftUI API (Task 6, 2026-10-13)
Result: same-named declarations in the app module shadow the SDK's macOS-unavailable ones, including types (`NavigationBarItem`), static members (`ToolbarItemPlacement.topBarLeading`) and View methods (`navigationBarTitleDisplayMode`, `fullScreenCover`). No call-site edits were needed. File: ConduitMac/Compat/App/SwiftUIiOSModifiers.swift.
Mappings: topBarLeading -> .navigation, topBarTrailing -> .primaryAction, `.navigationBar` -> no-op (see below), fullScreenCover -> sheet, textInputAutocapitalization and keyboardType -> no-ops.
Correction (titlebar fix): `navigationBar` was first mapped to `.windowToolbar`, so upstream's `.toolbar(.hidden, for: .navigationBar)` (7 sites) and `.toolbarBackground(.hidden, for: .navigationBar)` (9 sites) hid the window toolbar and title bar, traffic lights included, once the persistent sidebar (SidebarView.swift:161) was in the main window. Mac windows have no iOS nav bar and the chrome must stay, so `.navigationBar` now lives on `MacNavigationBarPlacement`, with app-target `toolbar(_:for:)` and `toolbarBackground(_:for:)` overloads that return `self`. Guard: ConduitMacTests/WindowChromeTests.

## D5: Hover accessibility layer (2026-10-13)
What it does: `HoverAccessibilityEngine` (ConduitMac/Accessibility) installs one app-wide local event monitor. SwiftUI builds a window's accessibility tree only while an assistive client is attached, so the engine reads the element under the pointer through that tree and shows a tooltip from its label, a pointing-hand cursor over controls, and an optional highlight.
Undocumented selector: AppKit's enhanced-UI flag, `accessibilityEnhancedUserInterfaceAttribute` / `accessibilitySetEnhancedUserInterfaceAttribute:`, called with `perform` (no KVC; KVC raises `NSUnknownKeyException` on `SwiftUI.AppKitApplication`). Only `AccessibilityTreeBoost` names them.
Scoped and owned: the flag is turned on only while the pointer is moving over the key window of the active app, and off after 2 s idle, on click or key, and on deactivation. The engine tracks ownership and never clears a flag it did not set. It never clears the flag while `NSWorkspace.isVoiceOverEnabled` is true; it gives up ownership instead.
Kill switch: `defaults write com.meswan.hermes.mac conduit.mac.hoverTooltipsDisabled -bool YES` (read at launch; the engine is not installed).
Risks: undocumented API that Apple can change or remove; verified only on macOS 27. If the selectors stop answering, the engine logs a warning and tooltips degrade silently. While the flag is on AppKit may slow window animations.

## D6: Mac split layout (2026-10-13)
Result: on Mac the persistent-sidebar branch of `RootView.sidebarLayoutContent` is a `NavigationSplitView` (`MacSplitLayout`, ConduitMac/App/MacSidebarState.swift) instead of the fixed-width HStack. The sidebar column is user-resizable via `.navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)`. Column visibility is bound to `@AppStorage("conduit.mac.sidebarVisible")` (default true; `.all` vs `.detailOnly`). Toggle Sidebar (Cmd-Ctrl-S) flips that key. `conduit.ipadPersistentSidebar` stays registered true by `MacDefaults` so the persistent path is always taken; it no longer has a Mac toggle.
Detail routing: the sidebar always shows `SessionList()` (SidebarView gate). The existing tab picker writes `conduit.sidebarTab`; `MacDetailRouter` maps it through `SidebarTab.migrated(rawValue:)` to chat, `BotRosterView`, `CronList` or `KanbanView` in the detail column. Opening a session (`AppState.activeSessionId` becomes non-nil) or a group-chat room (`activeRoomSurface`) sets the tab back to Sessions.
