# Mac Session Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scrollable strip of session tabs in the Mac chat toolbar, replacing the title pill, with browser-style tab shortcuts.

**Architecture:** A pure value model (`MacSessionTabsModel`) holds tabs, the active tab and a closed stack. A main-actor store (`MacSessionTabsStore`) persists the model per dashboard and profile, follows `AppState` through Combine, and opens sessions through `requestOpenSession`. A SwiftUI strip (`MacSessionTabStrip`) renders the store in the toolbar's principal slot via one gated edit in `RootView`; menu commands in `ConduitCommands` drive the store.

**Tech Stack:** Swift 6 / SwiftUI / AppKit on macOS 14+, Combine, XCTest. xcodegen project (`project.yml`), scheme `ConduitMac`.

**Spec:** `docs/superpowers/specs/2026-10-14-mac-session-tabs-design.md`

## Global Constraints

- Mac-only code lives under `ConduitMac/`. iOS behaviour is unchanged.
- Upstream edits (`Conduit/`, `Shared/`): `#if os(macOS)` gate, every gate tagged `// MAC:`, one row each in `docs/macos/PORTING_LEDGER.md`. `git diff <base> -- Conduit Shared` removes zero lines.
- No edits to `Conduit/Services/AppState.swift`.
- Tabs match sessions by `SessionSummary.id` and `alternateIds`.
- Persistence key: `conduit.mac.sessionTabs.<dashboardID or "none">.<profile>`; closed stack not persisted; closed stack limit 10.
- Tab pill: 28 pt tall, 120 to 220 pt wide; active fill `Color.conduitAccent`; no second glass layer on the toolbar platter (D7).
- Shortcuts: Cmd-1..8 tab N, Cmd-9 last tab, Ctrl-Tab and Cmd-Shift-] next tab (wrap), Ctrl-Shift-Tab and Cmd-Shift-[ previous tab (wrap), Cmd-W close tab, Cmd-Shift-T reopen, Ctrl-Cmd-1..4 panes, Cmd-[ / Cmd-] unchanged.
- Tab commands do nothing while a sheet is attached (`MacKeyboardActions.commandsBlocked`); Cmd-W in a window other than the main chat window closes that window.
- Tests: injected `UserDefaults` suites (`HostedTestSupport.makeSuite`/`dropSuite`), polling waits (`HostedTestSupport.waitUntil`), explicit teardown, no fixed sleeps. Never touch the live app's defaults.
- Build: `xcodegen generate` first; `xcodebuild test -scheme ConduitMac -destination 'platform=macOS'`; iOS check `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. Never two xcodebuilds on one checkout. Known flaky: `LiquidOrbViewMacTests.testHiddenWindowStopsTheMeterAndShowingResumesIt`.
- Safety: the user's own Conduit is running. Do not quit it, click it or type into it; never touch a Conduit login form.

## Review Focus

1. Opening a session the user then deletes from the sidebar (not from the tab): the tab must disappear, and a rename must not remove it. Test in Task 2 (`MacSessionDeletionDetector`).
2. Re-keyed session id (draft id replaced by the gateway id after the first message): one tab, not two. Test in Task 1 (`rekey`) and Task 2 (`catalogChanged`).
3. Profile or dashboard switch while tabs are open: the other scope's tabs appear, and switching back restores the first set. Test in Task 2.
4. Cmd-W in the Settings window or another non-chat window closes that window instead of a tab. Test in Task 4.
5. Many tabs (30+): the strip scrolls, the active tab stays visible, the window minimum width (820) still fits. Test in Task 3.

## File Map

- Create `ConduitMac/Tabs/MacSessionTabsModel.swift`: pure model (Task 1).
- Create `ConduitMac/Tabs/MacSessionTabsStore.swift`: store, persistence, AppState binding, deletion detector (Task 2).
- Create `ConduitMac/Tabs/MacSessionTabStrip.swift`: the strip view (Task 3).
- Modify `Conduit/Views/RootView.swift` (`chatToolbarContent`, principal item, about line 351): gate (Task 3).
- Modify `ConduitMac/App/ConduitMacApp.swift`: bind the store, pass it to commands (Task 2 binds; Task 4 passes).
- Modify `ConduitMac/App/ConduitCommands.swift`, `ConduitMac/App/MacKeyboardShortcuts.swift`: shortcuts (Task 4).
- Tests: `ConduitMacTests/MacSessionTabsModelTests.swift`, `MacSessionTabsStoreTests.swift`, `MacSessionTabStripTests.swift`, `MacSessionTabsCommandsTests.swift`; update `ConduitMacTests/MacKeyboardTests.swift`.
- Docs: `docs/macos/DECISIONS.md` (D11, D10 table update), `PORTING_LEDGER.md`, `SMOKE_CHECKLIST.md`.

`ConduitMac/` sources are picked up by the folder glob in `project.yml`; confirm with `grep -n "ConduitMac" project.yml` and re-run `xcodegen generate` after adding files.

---

### Task 1: Tab model

**Files:**
- Create: `ConduitMac/Tabs/MacSessionTabsModel.swift`
- Test: `ConduitMacTests/MacSessionTabsModelTests.swift`

**Interfaces:**
- Produces:
  - `struct MacSessionTab: Codable, Equatable { var id: String; var title: String; var unavailable: Bool }`
  - `struct MacSessionTabsModel: Codable, Equatable` with `tabs: [MacSessionTab]`, `activeID: String?`, `closed: [MacSessionTabsModel.ClosedTab]` (not encoded), `static let closedLimit = 10`
  - `enum MacSessionTabsModel.Direction { case previous, next }`
  - `enum MacSessionTabsModel.CloseResult: Equatable { case notFound, closedInactive, activate(String), closedLast }`
  - mutating: `open(_ id: String, title: String)`, `clearActive()`, `close(_ id: String) -> CloseResult`, `reopen() -> String?`, `remove(_ id: String)`, `rekey(_ old: String, to new: String)`, `markUnavailable(_ id: String)`, `updateTitle(_ id: String, _ title: String)`
  - queries: `index(of id: String) -> Int?`, `id(forShortcut n: Int) -> String?`, `neighbor(_ direction: Direction) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

final class MacSessionTabsModelTests: XCTestCase {
    private func model(_ ids: [String], active: String? = nil) -> MacSessionTabsModel {
        var m = MacSessionTabsModel()
        for id in ids { m.open(id, title: id.uppercased()) }
        if let active { m.open(active, title: active.uppercased()) }
        return m
    }

    func testOpenAppendsAndActivates() {
        var m = MacSessionTabsModel()
        m.open("a", title: "A")
        m.open("b", title: "B")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(m.activeID, "b")
    }

    func testOpenExistingSelectsWithoutAddingAndRefreshesTitle() {
        var m = model(["a", "b"])
        m.open("a", title: "Renamed")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(m.activeID, "a")
        XCTAssertEqual(m.tabs[0].title, "Renamed")
    }

    func testOpenClearsUnavailable() {
        var m = model(["a"])
        m.markUnavailable("a")
        XCTAssertTrue(m.tabs[0].unavailable)
        m.open("a", title: "A")
        XCTAssertFalse(m.tabs[0].unavailable)
    }

    func testCloseActivePrefersRightNeighbourThenLeft() {
        var m = model(["a", "b", "c"], active: "b")
        XCTAssertEqual(m.close("b"), .activate("c"))
        XCTAssertEqual(m.activeID, "c")
        XCTAssertEqual(m.close("c"), .activate("a"))
        XCTAssertEqual(m.tabs.map(\.id), ["a"])
    }

    func testCloseInactiveKeepsActive() {
        var m = model(["a", "b", "c"], active: "c")
        XCTAssertEqual(m.close("a"), .closedInactive)
        XCTAssertEqual(m.activeID, "c")
    }

    func testCloseLastTab() {
        var m = model(["a"])
        XCTAssertEqual(m.close("a"), .closedLast)
        XCTAssertTrue(m.tabs.isEmpty)
        XCTAssertNil(m.activeID)
    }

    func testCloseUnknownIsNotFound() {
        var m = model(["a"])
        XCTAssertEqual(m.close("zzz"), .notFound)
        XCTAssertEqual(m.tabs.count, 1)
    }

    func testReopenRestoresIndexMostRecentFirst() {
        var m = model(["a", "b", "c"], active: "c")
        _ = m.close("a")
        _ = m.close("b")
        XCTAssertEqual(m.reopen(), "b")
        XCTAssertEqual(m.tabs.map(\.id), ["b", "c"])
        XCTAssertEqual(m.reopen(), "a")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(m.activeID, "a")
        XCTAssertNil(m.reopen())
    }

    func testReopenClampsIndexAndSkipsAlreadyOpen() {
        var m = model(["a", "b", "c"], active: "a")
        _ = m.close("c")          // index 2
        _ = m.close("b")          // index 1
        m.open("c", title: "C")   // c is open again
        XCTAssertEqual(m.reopen(), "b")
        XCTAssertEqual(m.reopen(), nil, "c is already open, so its entry is dropped")
        XCTAssertEqual(m.tabs.map(\.id), ["a", "b", "c"])
    }

    func testClosedStackKeepsTen() {
        var m = model((0..<12).map { "s\($0)" })
        for i in 0..<12 { _ = m.close("s\(i)") }
        XCTAssertEqual(m.closed.count, MacSessionTabsModel.closedLimit)
        XCTAssertEqual(m.closed.first?.tab.id, "s11")
    }

    func testShortcutIndexEightThenLast() {
        let m = model((1...10).map { "s\($0)" })
        XCTAssertEqual(m.id(forShortcut: 1), "s1")
        XCTAssertEqual(m.id(forShortcut: 8), "s8")
        XCTAssertEqual(m.id(forShortcut: 9), "s10")
        XCTAssertNil(model(["a", "b"]).id(forShortcut: 5))
        XCTAssertEqual(model(["a", "b"]).id(forShortcut: 9), "b")
        XCTAssertNil(MacSessionTabsModel().id(forShortcut: 9))
    }

    func testNeighbourWraps() {
        let m = model(["a", "b", "c"], active: "c")
        XCTAssertEqual(m.neighbor(.next), "a")
        XCTAssertEqual(m.neighbor(.previous), "b")
        XCTAssertNil(model(["a"]).neighbor(.next), "a single tab has no neighbour")
        XCTAssertNil(MacSessionTabsModel().neighbor(.next))
    }

    func testNeighbourWithNoActiveEntersAtTheEnds() {
        var m = model(["a", "b"])
        m.clearActive()
        XCTAssertEqual(m.neighbor(.next), "a")
        XCTAssertEqual(m.neighbor(.previous), "b")
    }

    func testRemoveDoesNotFeedReopen() {
        var m = model(["a", "b"], active: "a")
        m.remove("a")
        XCTAssertEqual(m.tabs.map(\.id), ["b"])
        XCTAssertNil(m.activeID)
        XCTAssertNil(m.reopen())
    }

    func testRekeyKeepsPositionAndActiveAndMergesDuplicates() {
        var m = model(["draft", "b"], active: "draft")
        m.rekey("draft", to: "real")
        XCTAssertEqual(m.tabs.map(\.id), ["real", "b"])
        XCTAssertEqual(m.activeID, "real")
        var dup = model(["draft", "real"], active: "draft")
        dup.rekey("draft", to: "real")
        XCTAssertEqual(dup.tabs.map(\.id), ["real"], "never two tabs for one session")
        XCTAssertEqual(dup.activeID, "real")
    }

    func testCodableRoundTripDropsClosedStack() throws {
        var m = model(["a", "b"], active: "a")
        m.markUnavailable("b")
        _ = m.close("a")
        m.open("a", title: "A")
        let decoded = try JSONDecoder().decode(MacSessionTabsModel.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded.tabs, m.tabs)
        XCTAssertEqual(decoded.activeID, m.activeID)
        XCTAssertTrue(decoded.closed.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabsModelTests`
Expected: build failure, `cannot find 'MacSessionTabsModel' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One session tab (D11). `title` is the last known title, shown while the
/// session is outside the loaded catalog.
struct MacSessionTab: Codable, Equatable {
    var id: String
    var title: String
    var unavailable = false
}

/// The Mac session tab strip's state (D11): pure, no AppKit, no AppState.
struct MacSessionTabsModel: Codable, Equatable {
    static let closedLimit = 10

    enum Direction { case previous, next }

    enum CloseResult: Equatable {
        case notFound
        case closedInactive
        /// The active tab closed; this neighbour is now active and must be opened.
        case activate(String)
        /// The only tab closed.
        case closedLast
    }

    struct ClosedTab: Equatable {
        let tab: MacSessionTab
        let index: Int
    }

    private(set) var tabs: [MacSessionTab] = []
    private(set) var activeID: String?
    /// Most recent first. Not persisted.
    private(set) var closed: [ClosedTab] = []

    private enum CodingKeys: String, CodingKey { case tabs, activeID }

    func index(of id: String) -> Int? { tabs.firstIndex { $0.id == id } }

    /// Opening a session selects its tab, adding it at the end when missing.
    mutating func open(_ id: String, title: String) {
        if let index = index(of: id) {
            tabs[index].title = title
            tabs[index].unavailable = false
        } else {
            tabs.append(MacSessionTab(id: id, title: title))
        }
        activeID = id
    }

    /// No session is active (a room is open, or nothing is open yet).
    mutating func clearActive() { activeID = nil }

    mutating func close(_ id: String) -> CloseResult {
        guard let index = index(of: id) else { return .notFound }
        let tab = tabs.remove(at: index)
        closed.insert(ClosedTab(tab: tab, index: index), at: 0)
        if closed.count > Self.closedLimit { closed.removeLast(closed.count - Self.closedLimit) }
        guard activeID == id else { return .closedInactive }
        guard !tabs.isEmpty else {
            activeID = nil
            return .closedLast
        }
        let next = tabs[min(index, tabs.count - 1)].id
        activeID = next
        return .activate(next)
    }

    /// Reopens the most recent closed tab that is not open again, at its old
    /// index (clamped), and makes it active. Entries already open are dropped.
    mutating func reopen() -> String? {
        while !closed.isEmpty {
            let entry = closed.removeFirst()
            guard index(of: entry.tab.id) == nil else { continue }
            tabs.insert(entry.tab, at: min(entry.index, tabs.count))
            activeID = entry.tab.id
            return entry.tab.id
        }
        return nil
    }

    /// The session was deleted: the tab goes, and reopen cannot bring it back.
    mutating func remove(_ id: String) {
        tabs.removeAll { $0.id == id }
        closed.removeAll { $0.tab.id == id }
        if activeID == id { activeID = nil }
    }

    /// The session's id changed (draft id to gateway id). One tab survives.
    mutating func rekey(_ old: String, to new: String) {
        guard old != new, let index = index(of: old) else { return }
        tabs[index].id = new
        if let duplicate = tabs.indices.first(where: { $0 != index && tabs[$0].id == new }) {
            tabs.remove(at: duplicate)
        }
        if activeID == old { activeID = new }
        closed.removeAll { $0.tab.id == old }
    }

    mutating func markUnavailable(_ id: String) {
        guard let index = index(of: id) else { return }
        tabs[index].unavailable = true
    }

    mutating func updateTitle(_ id: String, _ title: String) {
        guard let index = index(of: id), tabs[index].title != title else { return }
        tabs[index].title = title
    }

    /// Cmd-1 ... Cmd-8 pick that tab; Cmd-9 always picks the last.
    func id(forShortcut n: Int) -> String? {
        guard !tabs.isEmpty else { return nil }
        if n == 9 { return tabs.last?.id }
        guard (1...8).contains(n), n <= tabs.count else { return nil }
        return tabs[n - 1].id
    }

    /// Next / previous tab, wrapping. With no active tab, next enters at the
    /// first and previous at the last. A single tab has no neighbour.
    func neighbor(_ direction: Direction) -> String? {
        guard !tabs.isEmpty else { return nil }
        guard let activeID, let index = index(of: activeID) else {
            return direction == .next ? tabs.first?.id : tabs.last?.id
        }
        guard tabs.count > 1 else { return nil }
        let offset = direction == .next ? 1 : -1
        return tabs[(index + offset + tabs.count) % tabs.count].id
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabsModelTests`
Expected: all MacSessionTabsModelTests pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Tabs/MacSessionTabsModel.swift ConduitMacTests/MacSessionTabsModelTests.swift
git commit -m "macOS: session tab model (D11)"
```

---

### Task 2: Store, persistence, AppState binding

**Files:**
- Create: `ConduitMac/Tabs/MacSessionTabsStore.swift`
- Modify: `ConduitMac/App/ConduitMacApp.swift` (bind the shared store to `appState` once the window appears)
- Test: `ConduitMacTests/MacSessionTabsStoreTests.swift`

**Interfaces:**
- Consumes: `MacSessionTabsModel`, `MacSessionTab` (Task 1); `AppState.activeSessionId`, `activeChatSessionSummary`, `activeProfile`, `activeDashboardID`, `sessions`, `sessionMutationID`, `messages`, `requestOpenSession(_:onFailure:)`, `createNewSession()`, `requestChatScrollToTop()`; `SessionSummary.id`, `alternateIds`, `title`.
- Produces:
  - `@MainActor final class MacSessionTabsStore: ObservableObject` with `static let shared`, `@Published private(set) var model: MacSessionTabsModel`, `init(defaults: UserDefaults = .standard)`
  - `static func storageKey(dashboardID: UUID?, profile: String) -> String`
  - closures set by `bind(to:)` (tests set them directly): `var openSession: (String) -> Void`, `var startNewChat: () -> Void`, `var activeChatIsEmpty: () -> Bool`, `var scrollActiveToTop: () -> Void`
  - entry points: `setScope(dashboardID: UUID?, profile: String)`, `activeSessionChanged(_ id: String?, title: String?)`, `select(_ id: String)`, `selectShortcut(_ n: Int)`, `selectNeighbor(_ direction: MacSessionTabsModel.Direction)`, `close(_ id: String?)` (nil = active), `reopen()`, `sessionDeleted(_ id: String)`, `openFailed(_ id: String)`, `catalogChanged(_ sessions: [SessionSummary])`, `bind(to appState: AppState)`
  - `struct MacSessionDeletionDetector` with `mutating func mutationChanged(to id: String?, catalog: [SessionSummary]) -> String?` (returns the deleted id)
  - `extension SessionSummary { func macMatches(_ id: String) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabsStoreTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacSessionTabsStore!
    private var opened: [String] = []
    private var newChats = 0
    private var emptyChat = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacSessionTabsStore(defaults: suite.defaults)
        opened = []; newChats = 0; emptyChat = false
        store.openSession = { [unowned self] in self.opened.append($0) }
        store.startNewChat = { [unowned self] in self.newChats += 1 }
        store.activeChatIsEmpty = { [unowned self] in self.emptyChat }
        store.setScope(dashboardID: nil, profile: "default")
    }

    override func tearDown() async throws {
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    func testActiveSessionChangeAddsATab() {
        store.activeSessionChanged("a", title: "A")
        store.activeSessionChanged("b", title: "B")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(store.model.activeID, "b")
        store.activeSessionChanged(nil, title: nil)
        XCTAssertNil(store.model.activeID, "a room or nothing open: no tab selected")
    }

    func testSelectOpensOnceAndActiveTabScrollsToTop() {
        var scrolled = 0
        store.scrollActiveToTop = { scrolled += 1 }
        store.activeSessionChanged("a", title: "A")
        store.activeSessionChanged("b", title: "B")
        store.select("a")
        XCTAssertEqual(opened, ["a"])
        store.activeSessionChanged("a", title: "A")
        store.select("a")
        XCTAssertEqual(opened, ["a"], "the active tab does not reopen")
        XCTAssertEqual(scrolled, 1)
    }

    func testCloseActiveOpensNeighbour() {
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
        store.select("b"); store.activeSessionChanged("b", title: "b")
        opened = []
        store.close(nil)
        XCTAssertEqual(opened, ["c"])
    }

    func testCloseLastStartsNewChatUnlessAlreadyEmpty() {
        store.activeSessionChanged("a", title: "A")
        emptyChat = true
        store.close(nil)
        XCTAssertEqual(store.model.tabs.map(\.id), ["a"], "an empty last chat stays")
        XCTAssertEqual(newChats, 0)
        emptyChat = false
        store.close(nil)
        XCTAssertTrue(store.model.tabs.isEmpty)
        XCTAssertEqual(newChats, 1)
    }

    func testReopenOpensTheSession() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        store.close("a")
        opened = []
        store.reopen()
        XCTAssertEqual(opened, ["a"])
    }

    func testShortcutsAndNeighbours() {
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
        store.selectShortcut(1)
        store.selectShortcut(9)  // c is active: no open
        store.selectNeighbor(.next)
        XCTAssertEqual(opened, ["a", "a"])
    }

    func testPersistsPerScopeAndRestores() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0.uppercased()) }
        store.setScope(dashboardID: nil, profile: "work")
        XCTAssertTrue(store.model.tabs.isEmpty)
        store.activeSessionChanged("w", title: "W")
        store.setScope(dashboardID: nil, profile: "default")
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(store.model.tabs.map(\.title), ["A", "B"])

        let reloaded = MacSessionTabsStore(defaults: suite.defaults)
        reloaded.setScope(dashboardID: nil, profile: "work")
        XCTAssertEqual(reloaded.model.tabs.map(\.id), ["w"])
        XCTAssertEqual(reloaded.model.activeID, "w")
    }

    func testStorageKey() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(MacSessionTabsStore.storageKey(dashboardID: id, profile: "default"),
                       "conduit.mac.sessionTabs.00000000-0000-0000-0000-000000000001.default")
        XCTAssertEqual(MacSessionTabsStore.storageKey(dashboardID: nil, profile: "p"), "conduit.mac.sessionTabs.none.p")
    }

    func testOpenFailureMarksUnavailableAndDeleteRemoves() {
        ["a", "b"].forEach { store.activeSessionChanged($0, title: $0) }
        store.openFailed("a")
        XCTAssertTrue(store.model.tabs[0].unavailable)
        store.sessionDeleted("a")
        XCTAssertEqual(store.model.tabs.map(\.id), ["b"])
    }

    func testCatalogRekeysAndRetitlesButNeverPrunes() {
        store.activeSessionChanged("draft", title: "New conversation")
        store.activeSessionChanged("old", title: "Old")
        let real = SessionSummary.macTestSummary(id: "real", alternateIds: ["draft"], title: "Laravel")
        store.catalogChanged([real])
        XCTAssertEqual(store.model.tabs.map(\.id), ["real", "old"], "old is outside the loaded page, not deleted")
        XCTAssertEqual(store.model.tabs[0].title, "Laravel")
    }
}

final class MacSessionDeletionDetectorTests: XCTestCase {
    func testDeletionIsAMutationWhoseSessionLeftTheCatalog() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        XCTAssertNil(detector.mutationChanged(to: "a", catalog: [a]))
        XCTAssertEqual(detector.mutationChanged(to: nil, catalog: []), "a")
    }

    func testRenameIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        let a = SessionSummary.macTestSummary(id: "a", alternateIds: [], title: "A")
        _ = detector.mutationChanged(to: "a", catalog: [a])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: [a]))
    }

    func testUnlistedMutationIsNotADeletion() {
        var detector = MacSessionDeletionDetector()
        _ = detector.mutationChanged(to: "x", catalog: [])
        XCTAssertNil(detector.mutationChanged(to: nil, catalog: []))
    }
}
```

`SessionSummary.macTestSummary` is a test helper: add it at the bottom of `MacSessionTabsStoreTests.swift`, building a `SessionSummary` through its memberwise initializer. Read `struct SessionSummary` in `Conduit/Models/Models.swift` (about line 770) and pass `id`, `alternateIds`, `title`, and the minimal values for the remaining non-defaulted properties (`model: ""`, `updatedLabel: ""`, `source:` the first case of `SessionSource`, `isActive: false`, `isArchived: false`, and any others the initializer requires). If an existing test already has such a helper (`grep -rn "SessionSummary(" ConduitMacTests`), reuse it instead.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabsStoreTests -only-testing:ConduitMacTests/MacSessionDeletionDetectorTests`
Expected: build failure, `cannot find 'MacSessionTabsStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Combine
import Foundation

extension SessionSummary {
    /// Tabs match a session by its id or any of its alternate ids.
    func macMatches(_ id: String) -> Bool { self.id == id || alternateIds.contains(id) }
}

/// Spots a deletion without AppState edits: a session mutation (rename or
/// delete) ended and its session, listed when the mutation began, is gone.
struct MacSessionDeletionDetector {
    private var pending: (id: String, wasListed: Bool)?

    mutating func mutationChanged(to id: String?, catalog: [SessionSummary]) -> String? {
        if let id {
            pending = (id, catalog.contains { $0.macMatches(id) })
            return nil
        }
        defer { pending = nil }
        guard let pending, pending.wasListed, !catalog.contains(where: { $0.macMatches(pending.id) }) else { return nil }
        return pending.id
    }
}

/// The session tabs of the current dashboard and profile (D11).
@MainActor
final class MacSessionTabsStore: ObservableObject {
    static let shared = MacSessionTabsStore()

    @Published private(set) var model = MacSessionTabsModel()

    var openSession: (String) -> Void = { _ in }
    var startNewChat: () -> Void = {}
    var activeChatIsEmpty: () -> Bool = { false }
    var scrollActiveToTop: () -> Void = {}

    private let defaults: UserDefaults
    private var scopeKey: String?
    private var deletionDetector = MacSessionDeletionDetector()
    private var bindings: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func storageKey(dashboardID: UUID?, profile: String) -> String {
        "conduit.mac.sessionTabs.\(dashboardID?.uuidString ?? "none").\(profile)"
    }

    func setScope(dashboardID: UUID?, profile: String) {
        let key = Self.storageKey(dashboardID: dashboardID, profile: profile)
        guard key != scopeKey else { return }
        save()
        scopeKey = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(MacSessionTabsModel.self, from: data) {
            model = stored
        } else {
            model = MacSessionTabsModel()
        }
    }

    func activeSessionChanged(_ id: String?, title: String?) {
        if let id { model.open(id, title: title ?? model.tabs.first { $0.id == id }?.title ?? "") }
        else { model.clearActive() }
        save()
    }

    func select(_ id: String) {
        guard model.index(of: id) != nil else { return }
        if model.activeID == id { scrollActiveToTop(); return }
        openSession(id)
    }

    func selectShortcut(_ n: Int) {
        guard let id = model.id(forShortcut: n), id != model.activeID else { return }
        openSession(id)
    }

    func selectNeighbor(_ direction: MacSessionTabsModel.Direction) {
        guard let id = model.neighbor(direction) else { return }
        openSession(id)
    }

    /// nil closes the active tab (Cmd-W).
    func close(_ id: String?) {
        guard let id = id ?? model.activeID else { return }
        if model.tabs.count == 1, model.activeID == id, activeChatIsEmpty() { return }
        switch model.close(id) {
        case .activate(let next): openSession(next)
        case .closedLast: startNewChat()
        case .closedInactive, .notFound: break
        }
        save()
    }

    func reopen() {
        guard let id = model.reopen() else { return }
        save()
        openSession(id)
    }

    func sessionDeleted(_ id: String) {
        model.remove(id)
        save()
    }

    func openFailed(_ id: String) {
        model.markUnavailable(id)
        save()
    }

    /// Re-keys tabs whose id became an alternate id, and refreshes titles.
    /// Never removes a tab: the catalog is paged.
    func catalogChanged(_ sessions: [SessionSummary]) {
        var changed = model
        for tab in model.tabs {
            guard let session = sessions.first(where: { $0.macMatches(tab.id) }) else { continue }
            if session.id != tab.id { changed.rekey(tab.id, to: session.id) }
            changed.updateTitle(session.id, session.title)
        }
        guard changed != model else { return }
        model = changed
        save()
    }

    func bind(to appState: AppState) {
        guard bindings.isEmpty else { return }
        openSession = { [weak appState, weak self] id in
            appState?.dismissSidebarDrawer()
            _ = appState?.requestOpenSession(id) { self?.openFailed(id) }
        }
        startNewChat = { [weak appState] in Task { await appState?.createNewSession() } }
        activeChatIsEmpty = { [weak appState] in appState?.messages.isEmpty ?? false }
        scrollActiveToTop = { [weak appState] in appState?.requestChatScrollToTop() }

        appState.$activeProfile
            .sink { [weak self, weak appState] profile in
                self?.setScope(dashboardID: appState?.activeDashboardID, profile: profile)
            }
            .store(in: &bindings)
        appState.$activeSessionId
            .removeDuplicates()
            .sink { [weak self, weak appState] id in
                // didSet has run; read the summary on the next turn so its title is current.
                DispatchQueue.main.async {
                    guard let self, let appState else { return }
                    self.setScope(dashboardID: appState.activeDashboardID, profile: appState.activeProfile)
                    let summary = appState.activeChatSessionSummary
                    self.activeSessionChanged(summary?.id ?? id, title: summary?.title ?? (id == nil ? nil : appState.displayedChatTitle))
                }
            }
            .store(in: &bindings)
        appState.$sessions
            .sink { [weak self] sessions in DispatchQueue.main.async { self?.catalogChanged(sessions) } }
            .store(in: &bindings)
        appState.$sessionMutationID
            .sink { [weak self, weak appState] id in
                DispatchQueue.main.async {
                    guard let self, let appState else { return }
                    if let deleted = self.deletionDetector.mutationChanged(to: id, catalog: appState.sessions) {
                        self.sessionDeleted(deleted)
                    }
                }
            }
            .store(in: &bindings)
    }

    private func save() {
        guard let scopeKey, let data = try? JSONEncoder().encode(model) else { return }
        defaults.set(data, forKey: scopeKey)
    }
}
```

Note on `sessionMutationID`'s ordering: `deleteSession` sets the id, awaits the HTTP call, removes the session from the catalog, then clears the id in `defer`. The `DispatchQueue.main.async` hop reads the catalog after the removal. The begin-mutation read happens before the removal. Verify with `sed -n 15025,15060p Conduit/Services/AppState.swift` that this order still holds; if `sessions` is not `@Published` with a public getter, read `grep -n "var sessions" Conduit/Services/AppState.swift` and use what the sidebar uses.

Wire in `ConduitMac/App/ConduitMacApp.swift`, on the primary `WindowGroup` content, next to the existing `.environmentObject(appState)`:

```swift
.task { MacSessionTabsStore.shared.bind(to: appState) }
```

`bind` is idempotent (`guard bindings.isEmpty`).

Concurrency: if the compiler rejects calling main-actor methods from the `sink` closures, replace each `DispatchQueue.main.async { ... }` hop with `.receive(on: RunLoop.main)` before `.sink` and wrap the body in `MainActor.assumeIsolated { ... }`. The hop exists so the read happens after `AppState`'s property observers ran; `receive(on:)` keeps that.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabsStoreTests -only-testing:ConduitMacTests/MacSessionDeletionDetectorTests -only-testing:ConduitMacTests/MacSessionTabsModelTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ConduitMac/Tabs/MacSessionTabsStore.swift ConduitMac/App/ConduitMacApp.swift ConduitMacTests/MacSessionTabsStoreTests.swift
git commit -m "macOS: session tab store with per-profile persistence and AppState binding (D11)"
```

---

### Task 3: Tab strip view and the RootView gate

**Files:**
- Create: `ConduitMac/Tabs/MacSessionTabStrip.swift`
- Modify: `Conduit/Views/RootView.swift` (principal `ToolbarItem` in `chatToolbarContent`, about line 351)
- Modify: `docs/macos/PORTING_LEDGER.md` (one row)
- Test: `ConduitMacTests/MacSessionTabStripTests.swift`

**Interfaces:**
- Consumes: `MacSessionTabsStore` (`model`, `select`, `close`), `MacSessionTab`; `AppState.sessions`, `sessionLiveStatus(_:)`, `isSessionUnread(_:)`, `isBusy`, `activeSessionId`; `SessionActionMenuItems(session:onRename:onDelete:)` (RootView/Sidebar, already used by `ChatTitleControl`); `SessionStatusFilter.color`.
- Produces: `struct MacSessionTabStrip: View { init(store: MacSessionTabsStore = .shared, onRename: @escaping (SessionSummary) -> Void, onDelete: @escaping (SessionSummary) -> Void) }`; `enum MacSessionTabMetrics { static let height: CGFloat = 28; static let minWidth: CGFloat = 120; static let maxWidth: CGFloat = 220 }`.

- [ ] **Step 1: Write the failing tests**

```swift
import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabStripTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var window: NSWindow?

    override func setUp() async throws { suite = HostedTestSupport.makeSuite() }
    override func tearDown() async throws {
        window?.close(); window = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func store(_ count: Int, active: Int) -> MacSessionTabsStore {
        let store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        for i in 0..<count { store.activeSessionChanged("s\(i)", title: "Session number \(i)") }
        store.activeSessionChanged("s\(active)", title: "Session number \(active)")
        return store
    }

    private func host(_ store: MacSessionTabsStore, width: CGFloat) -> NSWindow {
        let view = MacSessionTabStrip(store: store, onRename: { _ in }, onDelete: { _ in })
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .frame(width: width, height: 44)
        let window = HostedTestSupport.host(view, size: NSSize(width: width, height: 44))
        self.window = window
        return window
    }

    func testMetrics() {
        XCTAssertEqual(MacSessionTabMetrics.height, 28)
        XCTAssertEqual(MacSessionTabMetrics.minWidth, 120)
        XCTAssertEqual(MacSessionTabMetrics.maxWidth, 220)
    }

    func testEveryTabIsAnAccessibleButtonWithItsTitle() throws {
        let window = host(store(3, active: 1), width: 900)
        let labels = HostedTestSupport.waitUntil {
            (window.contentView?.accessibilityChildrenInNavigationOrder() ?? []).isEmpty == false
        }
        XCTAssertTrue(labels)
        let tree = AccessibilityProbe.labels(in: window)   // see note below
        for i in 0..<3 { XCTAssertTrue(tree.contains("Session number \(i)"), "\(tree)") }
    }

    func testActiveTabIsScrolledIntoViewWithManyTabs() throws {
        let window = host(store(30, active: 29), width: 600)
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.frame(of: "Session number 29", in: window).map { window.contentView!.bounds.contains($0) } ?? false
        }, "the active (last) tab is visible")
    }

    func testRendersInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = host(store(3, active: 0), width: 700)
            window.appearance = NSAppearance(named: appearance)
            HostedTestSupport.settle()
            let image = try XCTUnwrap(window.contentView?.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds))
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: image)
            XCTAssertGreaterThan(image.pixelsWide, 0)
            window.close(); self.window = nil
        }
    }
}
```

`AccessibilityProbe` is not an existing type: before writing these tests, read `ConduitMacTests/MacKeyboardTests.swift` (`MacSessionListKeyboardTests`, the ring tests) and `ConduitMacTests/ButtonShotsTests.swift` for how existing hosted tests read accessibility labels and frames (the SwiftUI AX tree is lazy; existing tests show the boost they use, `AccessibilityTreeBoost`). Put the two helpers `labels(in:)` and `frame(of:in:)` in `HostedTestSupport.swift` as `enum AccessibilityProbe`, built from that same code. Do not invent another approach.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabStripTests`
Expected: build failure, `cannot find 'MacSessionTabStrip' in scope`.

- [ ] **Step 3: Implement the strip**

```swift
import SwiftUI

enum MacSessionTabMetrics {
    static let height: CGFloat = 28
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 220
}

/// The chat toolbar's session tabs (D11), in place of the title pill.
struct MacSessionTabStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MacSessionTabsStore
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void

    init(store: MacSessionTabsStore = .shared,
         onRename: @escaping (SessionSummary) -> Void,
         onDelete: @escaping (SessionSummary) -> Void) {
        self.store = store
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.model.tabs, id: \.id) { tab in
                        MacSessionTabButton(
                            tab: tab,
                            session: appState.sessions.first { $0.macMatches(tab.id) },
                            isActive: tab.id == store.model.activeID,
                            onSelect: { store.select(tab.id) },
                            onClose: { store.close(tab.id) },
                            onRename: onRename,
                            onDelete: onDelete
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .mask(MacSessionTabEdgeFade())
            .onAppear { scroll(proxy) }
            .onChange(of: store.model.activeID) { _, _ in scroll(proxy) }
        }
        .frame(minWidth: MacSessionTabMetrics.minWidth, maxWidth: .infinity)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = store.model.activeID else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
    }
}

private struct MacSessionTabButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: MacSessionTab
    let session: SessionSummary?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    @State private var hovering = false

    private var title: String { session?.title ?? tab.title }

    private var liveStatus: SessionLiveStatus? {
        guard let session else { return nil }
        if let status = appState.sessionLiveStatus(session) { return status }
        return isActive && appState.isBusy ? .working : nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if let liveStatus {
                Circle()
                    .fill(liveStatus == .needsInput ? SessionStatusFilter.needsInput.color : SessionStatusFilter.working.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(liveStatus == .needsInput ? SessionStatusFilter.needsInput.title : SessionStatusFilter.working.title)
            } else if let session, !isActive, appState.isSessionUnread(session) {
                Circle().fill(SessionStatusFilter.unread.color).frame(width: 6, height: 6)
                    .accessibilityLabel(SessionStatusFilter.unread.title)
            }
            Text(title)
                .font(.callout.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isActive || hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Close tab"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: MacSessionTabMetrics.minWidth, maxWidth: MacSessionTabMetrics.maxWidth,
               minHeight: MacSessionTabMetrics.height, maxHeight: MacSessionTabMetrics.height)
        .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.secondary)
        .background(Capsule().fill(fill))
        .opacity(tab.unavailable ? 0.45 : 1)
        .contentShape(Capsule())
        .contentShape(.accessibility, Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.unavailable ? AppLocalization.string("Couldn't open this conversation") : title)
        .contextMenu {
            if let session {
                SessionActionMenuItems(session: session, onRename: { onRename(session) }, onDelete: { onDelete(session) })
            }
            Button(AppLocalization.string("Close Tab"), action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(AppLocalization.string("Close tab")), onClose)
    }

    private var fill: Color {
        if isActive { return .conduitAccent }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }
}

/// Fades the strip's ends so a scrolled-off tab reads as more to come
/// (same treatment as the sidebar filter-chip fade).
private struct MacSessionTabEdgeFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.03),
            .init(color: .black, location: 0.97),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}
```

Check before building: `SessionActionMenuItems` must be visible from `ConduitMac` (grep `struct SessionActionMenuItems`; if it is `private` in RootView, it needs an `internal` widening as an R4-widen gate with a ledger row: change `private struct` to `struct` inside `#if os(macOS)` is not possible for an access modifier, so instead add a Mac twin under `ConduitMac/Tabs/` that renders the same Rename and Delete buttons calling `onRename` / `onDelete`). Check the existing sidebar chip fade (`grep -rn "chip fade\|ChipFade\|fadeMask" Conduit/Views ConduitMac`) and reuse it instead of `MacSessionTabEdgeFade` if it is reachable.

- [ ] **Step 4: Gate RootView**

In `Conduit/Views/RootView.swift`, inside `chatToolbarContent`, change the principal item to:

```swift
            ToolbarItem(placement: .principal) {
                #if os(macOS) // MAC: session tabs replace the title pill (D11)
                MacSessionTabStrip(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 }
                )
                #else
                ChatTitleControl(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 }
                )
                #endif // MAC:
            }
```

The `ChatTitleControl(...)` lines must stay byte-identical (no removed lines in `git diff -- Conduit`). Then check the width: build and host the chat toolbar the way `ConduitMacTests/ToolbarPlatterGeometryTests.swift` does, at window width 1200 with the sidebar shown; the strip's frame must span at least 60% of the gap between the sidebar toggle and Refresh. If the principal slot does not grow, move the strip to `ToolbarItem(placement: .automatic)` placed first among the trailing items, keep the `ChatTitleControl` gate as above, and record the placement in D11. Add a test for the measured width to `MacSessionTabStripTests`.

Ledger row in `docs/macos/PORTING_LEDGER.md` (follow the existing table format):

`| Conduit/Views/RootView.swift (chatToolbarContent principal item) | R3 gate | MacSessionTabStrip replaces ChatTitleControl on Mac (D11); iOS path unchanged |`

- [ ] **Step 5: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabStripTests`
Expected: pass. Then the full suite once, and the iOS build.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac/Tabs/MacSessionTabStrip.swift Conduit/Views/RootView.swift docs/macos/PORTING_LEDGER.md ConduitMacTests/MacSessionTabStripTests.swift ConduitMacTests/HostedTestSupport.swift
git commit -m "macOS: session tab strip in the chat toolbar (D11)"
```

---

### Task 4: Tab commands and the pane move

**Files:**
- Modify: `ConduitMac/App/ConduitCommands.swift`, `ConduitMac/App/MacKeyboardShortcuts.swift`, `ConduitMac/App/ConduitMacApp.swift` (pass the store)
- Modify: `ConduitMacTests/MacKeyboardTests.swift` (pane modifiers, menu table)
- Create: `ConduitMacTests/MacSessionTabsCommandsTests.swift`
- Modify docs: `docs/macos/DECISIONS.md` (D11 new; D10 table: panes now Ctrl-Cmd-1..4), `docs/macos/SMOKE_CHECKLIST.md`

**Interfaces:**
- Consumes: `MacSessionTabsStore` (`selectShortcut`, `selectNeighbor`, `close`, `reopen`, `model`), `MacKeyboardActions.commandsBlocked(by:)`.
- Produces:
  - `MacSidebarShortcut.modifiers: EventModifiers` (`[.control, .command]`)
  - `@MainActor enum MacSessionTabsActions` with `static func isMainChatWindow(_ window: NSWindow?) -> Bool`, `static func closeTab(store:window:)`, `static func reopen(store:window:)`, `static func selectShortcut(_ n: Int, store:window:)`, `static func selectNeighbor(_ direction: MacSessionTabsModel.Direction, store:window:)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabsCommandsTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var store: MacSessionTabsStore!
    private var opened: [String] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        opened = []
        store.openSession = { [unowned self] in self.opened.append($0) }
        ["a", "b", "c"].forEach { store.activeSessionChanged($0, title: $0) }
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }; windows = []
        store = nil
        HostedTestSupport.dropSuite(suite)
    }

    private func window(identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = identifier.map(NSUserInterfaceItemIdentifier.init)
        windows.append(w)
        return w
    }

    func testMainChatWindowIsTheConduitPrimaryWindowGroup() {
        XCTAssertTrue(MacSessionTabsActions.isMainChatWindow(window(identifier: "conduit-primary-AppWindow-1")))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(window(identifier: "com_apple_SwiftUI_Settings_window")))
        XCTAssertFalse(MacSessionTabsActions.isMainChatWindow(nil))
    }

    func testCloseTabClosesTheActiveTabInTheChatWindow() {
        MacSessionTabsActions.closeTab(store: store, window: window(identifier: "conduit-primary-AppWindow-1"))
        XCTAssertEqual(store.model.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(opened, ["b"])
    }

    func testCmdWInAnotherWindowClosesThatWindowNotATab() {
        let other = window(identifier: "com_apple_SwiftUI_Settings_window")
        other.orderFront(nil)
        MacSessionTabsActions.closeTab(store: store, window: other)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(HostedTestSupport.waitUntil { !other.isVisible })
    }

    func testCommandsDoNothingUnderASheet() {
        let main = window(identifier: "conduit-primary-AppWindow-1")
        let sheet = window(identifier: nil)
        main.beginSheet(sheet)
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        MacSessionTabsActions.closeTab(store: store, window: main)
        MacSessionTabsActions.selectShortcut(1, store: store, window: main)
        MacSessionTabsActions.selectNeighbor(.next, store: store, window: main)
        MacSessionTabsActions.reopen(store: store, window: main)
        XCTAssertEqual(store.model.tabs.count, 3)
        XCTAssertTrue(opened.isEmpty)
        main.endSheet(sheet)
    }

    func testPanesMovedToControlCommand() {
        for shortcut in MacSidebarShortcut.allCases {
            XCTAssertEqual(shortcut.modifiers, [.control, .command])
        }
    }
}
```

In `ConduitMacTests/MacKeyboardTests.swift` (`MacKeyboardMenuTests.shortcuts()`), change the pane rows to `[.control, .command]` and add the tab rows. The SwiftUI shortcut for Cmd-Shift-] may surface in AppKit as key `"]"` with `[.shift, .command]` or as `"}"` with `.command`; run once, read the actual `keyEquivalent` / mask from the menu (print them in a failing assertion), and pin what AppKit reports:

```swift
        var table: [(String, String, NSEvent.ModifierFlags)] = MacSidebarShortcut.allCases.map { shortcut in
            ("/Go/\(shortcut.title)", String(shortcut.key.character), [.control, .command])
        }
        table += (1...8).map { ("/Go/Tab \($0)", "\($0)", NSEvent.ModifierFlags.command) }
        table += [
            ("/Go/Last Tab", "9", .command),
            ("/Go/Show Next Tab", "\t", .control),
            ("/Go/Show Previous Tab", "\t", [.control, .shift]),
            ("/File/Close Tab", "w", .command),
            ("/File/Reopen Closed Tab", "t", [.shift, .command]),
        ]
```

Add the Next Tab / Previous Tab (Cmd-Shift-] / Cmd-Shift-[) rows once their AppKit form is known. Also assert that `/File/Close Tab` precedes `/File/Close` for Cmd-W (the existing `testEveryShortcutIsInTheMenuAndWinsItsKey` covers this once the row is in the table).

Update `MacSidebarShortcutTests` only if a test asserts Command-only modifiers; the digit mapping is unchanged.

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS' -only-testing:ConduitMacTests/MacSessionTabsCommandsTests -only-testing:ConduitMacTests/MacKeyboardMenuTests`
Expected: build failure (`MacSessionTabsActions` missing), then menu-table failures.

- [ ] **Step 3: Implement**

In `MacKeyboardShortcuts.swift`, add to `MacSidebarShortcut`:

```swift
    /// Ctrl-Cmd: plain Cmd-digits select session tabs (D11).
    var modifiers: EventModifiers { [.control, .command] }
```

and add:

```swift
/// What the tab menu items do (D11). The store is injectable for tests.
@MainActor
enum MacSessionTabsActions {
    /// The chat window: SwiftUI names WindowGroup("Conduit", id: "conduit-primary")
    /// windows with that id as the prefix.
    static func isMainChatWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix("conduit-primary") ?? false
    }

    /// Cmd-W: a tab in the chat window, else that window's ordinary close.
    static func closeTab(store: MacSessionTabsStore = .shared, window: NSWindow?) {
        guard let window else { return }
        guard isMainChatWindow(window) else { window.performClose(nil); return }
        guard !MacKeyboardActions.commandsBlocked(by: window) else { return }
        store.close(nil)
    }

    static func reopen(store: MacSessionTabsStore = .shared, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        store.reopen()
    }

    static func selectShortcut(_ n: Int, store: MacSessionTabsStore = .shared, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        store.selectShortcut(n)
    }

    static func selectNeighbor(_ direction: MacSessionTabsModel.Direction, store: MacSessionTabsStore = .shared, window: NSWindow?) {
        guard isMainChatWindow(window), !MacKeyboardActions.commandsBlocked(by: window) else { return }
        store.selectNeighbor(direction)
    }
}
```

Verify the window identifier prefix live-safely: in a test, `grep -rn "conduit-primary" ConduitMac` shows the WindowGroup id; print `NSApp.windows.map { $0.identifier?.rawValue }` from a hosted test run (the test host is the real app, so its primary window exists) and adjust `isMainChatWindow` if SwiftUI uses a different form. Keep the test's identifier strings in step with what you observe.

In `ConduitCommands.swift`:
- add `@ObservedObject var tabs: MacSessionTabsStore`
- pane items: `.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)`
- inside `CommandGroup(replacing: .newItem)`, after New Chat:

```swift
            Button("Close Tab") { MacSessionTabsActions.closeTab(store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { MacSessionTabsActions.reopen(store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("t", modifiers: [.shift, .command])
```

- in the Go menu, before the pane items:

```swift
            ForEach(1...8, id: \.self) { n in
                Button("Tab \(n)") { MacSessionTabsActions.selectShortcut(n, store: tabs, window: NSApp.keyWindow) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("Last Tab") { MacSessionTabsActions.selectShortcut(9, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("9", modifiers: .command)
            Button("Next Tab") { MacSessionTabsActions.selectNeighbor(.next, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("]", modifiers: [.shift, .command])
            Button("Previous Tab") { MacSessionTabsActions.selectNeighbor(.previous, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut("[", modifiers: [.shift, .command])
            Button("Show Next Tab") { MacSessionTabsActions.selectNeighbor(.next, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { MacSessionTabsActions.selectNeighbor(.previous, store: tabs, window: NSApp.keyWindow) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
```

Do not add `.disabled` to these items (see the existing comment in ConduitCommands: a stale disabled item swallows its key).

In `ConduitMacApp.swift`: `.commands { ConduitCommands(appState: appState, tabs: .shared) }`.

Ctrl-Tab reaching the menu: add to `MacSessionTabsCommandsTests` a test that hosts `ComposerTextView` first responder in a window and asserts `textView.performKeyEquivalent(with:)` returns false for a Ctrl-Tab and a Ctrl-Shift-Tab `NSEvent.keyEvent` (same construction as the Cmd-[ test in `MacComposerKeyboardTests`), and that the session list modifier's `onKeyPress` handlers ignore Tab when Control is held (read `ConduitMac/Views/MacSessionKeyboard.swift`; if they consume it, add `!press.modifiers.contains(.control)` to the Tab guards and a test).

- [ ] **Step 4: Docs**

`docs/macos/DECISIONS.md`: add

```
## D11: Mac session tabs (2026-10-14)
Spec: docs/superpowers/specs/2026-10-14-mac-session-tabs-design.md. A scrollable strip of session tabs replaces the chat toolbar's title pill (RootView principal item, one gate). Every session open adds a tab; tabs persist per dashboard and profile (conduit.mac.sessionTabs.<dashboard>.<profile>); a tab is removed only on delete (detected from sessionMutationID plus the catalog, no AppState edit); a failed open marks the tab unavailable. Closing the last tab starts a new chat unless it is already empty. Shortcuts: Cmd-1..8 tab N, Cmd-9 last, Ctrl-Tab / Cmd-Shift-] next, Ctrl-Shift-Tab / Cmd-Shift-[ previous (wrap), Cmd-W close (other windows close as usual), Cmd-Shift-T reopen (last 10). Panes moved from Cmd-1..4 to Ctrl-Cmd-1..4. Components: MacSessionTabsModel (pure), MacSessionTabsStore, MacSessionTabStrip, MacSessionTabsActions. Out of scope: reorder, rooms as tabs, sync between Macs.
```

Fill in the toolbar placement actually used (principal or automatic) and the AppKit form of Cmd-Shift-] found in Step 1. In D10's shortcut table, change the pane row to Ctrl-Cmd-1..4 with "moved by D11". In `SMOKE_CHECKLIST.md` keyboard section, add: open 3 sessions and see 3 tabs; Cmd-1/Cmd-9/Ctrl-Tab; Cmd-W twice then Cmd-Shift-T; Cmd-W in Settings closes Settings; delete a session from the sidebar and its tab goes; rename keeps the tab; relaunch restores tabs; Ctrl-Cmd-1..4 switch panes.

- [ ] **Step 5: Run everything**

Run: `xcodegen generate && xcodebuild test -scheme ConduitMac -destination 'platform=macOS'` twice, then `xcodebuild build -scheme Conduit -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, then `git diff 9eb1e244 -- Conduit Shared | grep '^-[^-]'` (expect no output).
Expected: all pass except the known flaky orb test.

- [ ] **Step 6: Commit**

```bash
git add ConduitMac ConduitMacTests docs/macos
git commit -m "macOS: session tab shortcuts, panes on Ctrl-Cmd-1..4 (D11)"
```

---

## Execution notes

- Task order: 1, then 2, then 3 and 4 (3 and 4 touch different files and may run in parallel worktrees branched from Task 2's commit; merge 3 first, then rebase 4).
- After all tasks: whole-branch review against the spec and this plan's Review Focus, then merge into `macos`, run the full suite on the merge, remove worktrees.
