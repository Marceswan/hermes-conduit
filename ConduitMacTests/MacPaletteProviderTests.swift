import XCTest
@testable import ConduitMac

@MainActor
final class MacPaletteProviderTests: XCTestCase {
    private func snapshot(
        sessions: [SessionSummary] = [], active: String? = nil, slash: [SlashCommand] = [],
        profiles: [String] = ["default"], activeProfile: String = "default", running: Bool = false,
        sidebar: Bool = true, unread: Set<String> = []
    ) -> MacPaletteSnapshot {
        MacPaletteSnapshot(
            sessions: sessions, unreadSessionIDs: unread, activeSessionID: active, slashCommands: slash,
            profiles: profiles, activeProfile: activeProfile, isTurnRunning: running, sidebarVisible: sidebar
        )
    }

    private func items(_ s: MacPaletteSnapshot) -> [String: MacPaletteItem] {
        Dictionary(MacPaletteProvider.items(s).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testSessionsExcludeArchivedAndCarryKeywordsAndFlags() throws {
        let a = SessionSummary.paletteFixture(id: "a", title: "Laravel", model: "gpt-x", lastActivityAt: 5)
        let b = SessionSummary.paletteFixture(id: "b", title: "Old", archived: true)
        let all = items(snapshot(sessions: [a, b], active: "a", unread: ["a"]))
        XCTAssertNil(all["session:b"])
        let item = try XCTUnwrap(all["session:a"])
        XCTAssertEqual(item.title, "Laravel")
        XCTAssertEqual(item.action, .openSession("a"))
        XCTAssertTrue(item.keywords.contains("gpt-x") && item.keywords.contains("a"))
        XCTAssertTrue(item.isActiveSession && item.isUnread)
        XCTAssertEqual(item.lastActivityAt, 5)
    }

    func testSessionMatchesActiveIDThroughAlternateIDs() throws {
        var s = SessionSummary.paletteFixture(id: "real", title: "T")
        s.alternateIds = ["draft"]
        XCTAssertTrue(try XCTUnwrap(items(snapshot(sessions: [s], active: "draft"))["session:real"]).isActiveSession)
    }

    func testPinnedSessionsComeFirstInCatalogOrder() {
        let list = [SessionSummary.paletteFixture(id: "1", title: "One"), .paletteFixture(id: "2", title: "Two", pinned: true),
                    .paletteFixture(id: "3", title: "Three")]
        XCTAssertEqual(MacPaletteProvider.items(snapshot(sessions: list)).filter { $0.kind == .session }.map(\.id),
                       ["session:2", "session:1", "session:3"])
    }

    func testSlashFollowsCatalogAndMapsArgsHintToInsert() {
        let slash = [SlashCommand(name: "new", description: "Start over"),
                     SlashCommand(name: "title", aliases: ["rename"], description: "Rename", argsHint: "<name>")]
        let all = items(snapshot(active: "a", slash: slash))
        XCTAssertEqual(all["slash:new"]?.action, .runSlash("new"))
        XCTAssertEqual(all["slash:title"]?.action, .insertSlash("title"))
        XCTAssertEqual(all["slash:title"]?.title, "/title")
        XCTAssertTrue(all["slash:title"]!.keywords.contains("rename"))
        XCTAssertEqual(items(snapshot(active: "a", slash: [slash[0]])).keys.filter { $0.hasPrefix("slash:") }.sorted(), ["slash:new"])
    }

    func testNoActiveSessionDisablesSlashWithReason() {
        let all = items(snapshot(active: nil, slash: [SlashCommand(name: "new", description: "")]))
        XCTAssertEqual(all["slash:new"]?.isEnabled, false)
        XCTAssertEqual(all["slash:new"]?.disabledReason, AppLocalization.string("No active chat"))
        XCTAssertEqual(items(snapshot(active: "a", slash: [SlashCommand(name: "new", description: "")]))["slash:new"]?.isEnabled, true)
    }

    func testActiveProfileIsACheckRowAndNotRunnable() {
        let all = items(snapshot(profiles: ["default", "work"], activeProfile: "work"))
        XCTAssertEqual(all["profile:work"]?.isCurrent, true)
        XCTAssertEqual(all["profile:work"]?.isEnabled, false)
        XCTAssertEqual(all["profile:default"]?.action, .switchProfile("default"))
        XCTAssertEqual(all["profile:default"]?.isEnabled, true)
        XCTAssertNotNil(items(snapshot(profiles: [], activeProfile: "solo"))["profile:solo"], "falls back to [activeProfile]")
    }

    func testPanesModelAndStaticCommands() {
        let all = items(snapshot())
        for tab in SidebarTab.allCases { XCTAssertEqual(all["pane:\(tab.rawValue)"]?.action, .selectPane(tab)) }
        XCTAssertEqual(all["model:switch"]?.action, .openModelPicker)
        XCTAssertEqual(all["command:newChat"]?.action, .newChat)
        XCTAssertEqual(all["command:settings"]?.action, .openSettings)
        XCTAssertEqual(all["command:searchSessions"]?.action, .searchSessions)
        XCTAssertEqual(all["command:checkForUpdates"]?.action, .checkForUpdates)
        XCTAssertEqual(all["command:toggleSidebar"]?.action, .toggleSidebar)
    }

    func testToggleSidebarTitleFollowsVisibilityAndStopOnlyWhileRunning() {
        XCTAssertEqual(items(snapshot(sidebar: true))["command:toggleSidebar"]?.title, AppLocalization.string("Hide Sidebar"))
        XCTAssertEqual(items(snapshot(sidebar: false))["command:toggleSidebar"]?.title, AppLocalization.string("Show Sidebar"))
        XCTAssertNil(items(snapshot(running: false))["command:stopResponse"])
        XCTAssertEqual(items(snapshot(running: true))["command:stopResponse"]?.action, .stopResponse)
    }

    func testCheckForUpdatesDisabledWhenUnavailable() {
        var s = snapshot(); s.canCheckForUpdates = false
        XCTAssertEqual(items(s)["command:checkForUpdates"]?.isEnabled, false)
    }

    func testScopeParsing() {
        func parsed(_ raw: String) -> (MacPaletteScope, String) {
            let p = MacPaletteScope.parse(raw)
            return (p.scope, p.text)
        }
        XCTAssertTrue(parsed("/mod") == (.slash, "mod"))
        XCTAssertTrue(parsed(">new") == (.commands, "new"))
        XCTAssertTrue(parsed("@wo") == (.profiles, "wo"))
        XCTAssertTrue(parsed("#lar") == (.sessions, "lar"))
        XCTAssertTrue(parsed("  >new") == (.commands, "new"))
        XCTAssertTrue(parsed("a/b") == (.all, "a/b"), "a prefix after text is plain text")
        XCTAssertTrue(parsed(">") == (.commands, ""), "a bare prefix lists the whole scope")
        XCTAssertTrue(parsed("   ") == (.all, ""))
        XCTAssertTrue(parsed("") == (.all, ""))
    }

    func testScopeInclusion() {
        XCTAssertTrue(MacPaletteScope.commands.includes(.command) && MacPaletteScope.commands.includes(.pane) && MacPaletteScope.commands.includes(.model))
        XCTAssertFalse(MacPaletteScope.commands.includes(.session))
        XCTAssertTrue(MacPaletteScope.slash.includes(.slash) && !MacPaletteScope.slash.includes(.command))
        XCTAssertTrue(MacPaletteScope.profiles.includes(.profile) && !MacPaletteScope.profiles.includes(.slash))
        XCTAssertTrue(MacPaletteScope.sessions.includes(.session) && !MacPaletteScope.sessions.includes(.profile))
        XCTAssertTrue(MacPaletteKind.allCases.allSatisfy(MacPaletteScope.all.includes))
    }

    func testEmptyQuerySectionsOrderDedupeAndCollapse() {
        let slash = (1...8).map { SlashCommand(name: "c\($0)", description: "") }
        let sessions = (1...3).map { SessionSummary.paletteFixture(id: "s\($0)", title: "S\($0)") }
        let built = MacPaletteProvider.items(snapshot(sessions: sessions, active: "s1", slash: slash))
        let recent = built.filter { $0.id == "session:s2" || $0.id == "command:newChat" }
        let sections = MacPaletteProvider.sections(items: built, recents: recent)
        XCTAssertEqual(sections.map(\.title), [AppLocalization.string("Recent"), AppLocalization.string("Commands"),
                                              AppLocalization.string("Slash Commands"), AppLocalization.string("Chats")])
        XCTAssertEqual(sections[0].items.map(\.id), ["session:s2", "command:newChat"])
        XCTAssertFalse(sections[1].items.contains { $0.id == "command:newChat" }, "a recent row is not repeated")
        XCTAssertEqual(sections[2].items.count, MacPaletteProvider.collapsedSlashCount)
        XCTAssertEqual(sections[3].items.map(\.id), ["session:s1", "session:s3"])
        XCTAssertLessThanOrEqual(sections.flatMap(\.items).count, MacPaletteMatcher.rowLimit)
    }

    func testRecentSectionIsCappedAtEightAndOmittedWhenEmpty() {
        let built = MacPaletteProvider.items(snapshot())
        XCTAssertFalse(MacPaletteProvider.sections(items: built, recents: []).contains { $0.title == AppLocalization.string("Recent") })
        let many = Array(built.prefix(12))
        XCTAssertEqual(MacPaletteProvider.sections(items: built, recents: many)[0].items.count, MacPaletteRecents.shownLimit)
    }

    func testEmptyQueryCapsTotalRowsAtFifty() {
        let sessions = (0..<500).map { SessionSummary.paletteFixture(id: "s\($0)", title: "S\($0)") }
        let built = MacPaletteProvider.items(snapshot(sessions: sessions))
        XCTAssertEqual(MacPaletteProvider.sections(items: built, recents: []).flatMap(\.items).count, MacPaletteMatcher.rowLimit)
    }

    // MARK: - Review round 1

    func testSlashPolicyRunsInsertsOrAsks() {
        func mode(_ name: String, aliases: [String] = [], hint: String? = nil) -> MacPaletteSlashPolicy.Mode {
            MacPaletteSlashPolicy.mode(for: SlashCommand(name: name, aliases: aliases, description: "", argsHint: hint))
        }
        for name in ["new", "status", "usage", "version", "help", "model", "branch", "agents", "save", "debug"] {
            XCTAssertEqual(mode(name), .run, name)
        }
        XCTAssertEqual(mode("new", aliases: ["reset"]), .run)
        // A prompt is the argument: bare, these would run with nothing.
        for name in ["background", "queue", "steer", "goal", "personality", "approvals", "tools", "rollback"] {
            XCTAssertEqual(mode(name), .insert, name)
        }
        XCTAssertEqual(mode("bg"), .insert, "by alias")
        XCTAssertEqual(mode("something", aliases: ["q"]), .insert)
        XCTAssertEqual(mode("title", hint: "<name>"), .insert)
        XCTAssertEqual(mode("status", hint: "[x]"), .insert, "an argument hint always wins")
        XCTAssertEqual(mode("status", hint: "  "), .run, "a blank hint is no hint")
        // State changes and anything the palette does not know.
        for name in ["undo", "retry", "compress", "yolo", "stop", "my-skill", "deploy"] {
            XCTAssertEqual(mode(name), .confirmThenRun, name)
        }
        XCTAssertEqual(mode("compress", aliases: ["compact"]), .confirmThenRun)
    }

    func testProviderMapsPolicyToActionAndConfirmation() throws {
        let slash = [SlashCommand(name: "status", description: "Show status"),
                     SlashCommand(name: "background", aliases: ["bg"], description: "Run a prompt in the background"),
                     SlashCommand(name: "undo", description: "Remove the last exchange"),
                     SlashCommand(name: "refactor", description: "A skill")]
        let all = items(snapshot(active: "a", slash: slash))
        XCTAssertEqual(all["slash:status"]?.action, .runSlash("status"))
        XCTAssertNil(all["slash:status"]?.confirmation)
        XCTAssertEqual(all["slash:background"]?.action, .insertSlash("background"))
        XCTAssertNil(all["slash:background"]?.confirmation)
        XCTAssertEqual(all["slash:undo"]?.action, .runSlash("undo"))
        XCTAssertEqual(try XCTUnwrap(all["slash:undo"]?.confirmation).message, "/undo: Remove the last exchange")
        XCTAssertNotNil(all["slash:refactor"]?.confirmation, "unknown commands (skills, plugins) ask first")
    }

    func testStopResponseAlwaysCarriesAConfirmation() throws {
        let item = try XCTUnwrap(items(snapshot(running: true))["command:stopResponse"])
        XCTAssertEqual(item.confirmation?.confirmTitle, AppLocalization.string("Stop"))
    }
}
