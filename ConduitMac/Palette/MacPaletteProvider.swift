import Foundation

/// Everything the provider reads, copied out of AppState so the provider is
/// pure and tests build snapshots by hand (D18).
struct MacPaletteSnapshot {
    var sessions: [SessionSummary] = []
    var unreadSessionIDs: Set<String> = []
    var activeSessionID: String?
    var slashCommands: [SlashCommand] = []
    var profiles: [String] = []
    var activeProfile = "default"
    var isTurnRunning = false
    var sidebarVisible = true
    var canCheckForUpdates = true
    var dashboardID: UUID?

    static let empty = MacPaletteSnapshot()
}

/// `/`, `>`, `@`, `#` as the first character limit the palette to one kind of
/// result. The prefix is a filter, never part of the match text.
enum MacPaletteScope: Equatable {
    case all, slash, commands, profiles, sessions

    static func parse(_ raw: String) -> (scope: MacPaletteScope, text: String) {
        let trimmed = raw.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first else { return (.all, "") }
        let scope: MacPaletteScope
        switch first {
        case "/": scope = .slash
        case ">": scope = .commands
        case "@": scope = .profiles
        case "#": scope = .sessions
        default: return (.all, String(trimmed).trimmingCharacters(in: .whitespaces))
        }
        return (scope, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    func includes(_ kind: MacPaletteKind) -> Bool {
        switch self {
        case .all: return true
        case .slash: return kind == .slash
        case .commands: return kind == .command || kind == .pane || kind == .model
        case .profiles: return kind == .profile
        case .sessions: return kind == .session
        }
    }
}

/// How a slash command runs from the palette. `argsHint` alone is not enough:
/// the built-in catalog and the gateway's `pairs` catalog carry no hint at
/// all, so `/background`, `/queue` and `/steer` (a prompt is their argument)
/// would run bare, and `/undo`, `/compress` or a skill would run on one
/// Return. Commands known to be read-only or non-destructive run at once;
/// commands that take an argument are put in the composer; everything else
/// (state changes, skills, plugins, unknown gateway commands) asks first.
enum MacPaletteSlashPolicy {
    enum Mode: Equatable { case run, insert, confirmThenRun }

    private static let runsAtOnce: Set<String> = [
        "new", "reset", "branch", "fork", "model", "help", "commands", "status", "usage", "version",
        "agents", "tasks", "save", "debug",
    ]
    private static let takesArguments: Set<String> = [
        "background", "bg", "btw", "queue", "q", "steer", "goal", "personality", "approvals", "tools", "rollback",
    ]

    static func mode(for command: SlashCommand) -> Mode {
        if let hint = command.argsHint, !hint.trimmingCharacters(in: .whitespaces).isEmpty { return .insert }
        let names = Set(([command.name] + command.aliases).map { $0.lowercased() })
        if !names.isDisjoint(with: takesArguments) { return .insert }
        if !names.isDisjoint(with: runsAtOnce) { return .run }
        return .confirmThenRun
    }

    static func confirmation(for command: SlashCommand) -> MacPaletteConfirmation {
        MacPaletteConfirmation(
            title: AppLocalization.string("Run this command?"),
            message: "/" + command.name + (command.description.isEmpty ? "" : ": " + command.description),
            confirmTitle: AppLocalization.string("Run Command")
        )
    }
}

enum MacPaletteProvider {
    static let collapsedSlashCount = 5

    static func items(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        sessionItems(s) + slashItems(s) + profileItems(s) + commandItems(s)
    }

    // MARK: - Sources

    private static func sessionItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        let live = s.sessions.filter { !$0.isArchived }
        // The sidebar's own order is not reachable from here (SidebarView
        // keeps it private); pinned first, then catalog order, approximates it.
        let ordered = live.filter { $0.isPinned == true } + live.filter { $0.isPinned != true }
        return ordered.map { session in
            MacPaletteItem(
                id: "session:\(session.id)", kind: .session,
                title: session.title.isEmpty ? AppLocalization.string("Untitled chat") : session.title,
                subtitle: session.model, keywords: [session.model, session.id],
                isUnread: s.unreadSessionIDs.contains(session.id),
                isActiveSession: s.activeSessionID.map(session.macMatches) ?? false,
                lastActivityAt: session.lastActivityAt,
                action: .openSession(session.id)
            )
        }
    }

    private static func slashItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        let hasChat = s.activeSessionID != nil
        return s.slashCommands.map { command in
            let mode = MacPaletteSlashPolicy.mode(for: command)
            return MacPaletteItem(
                id: "slash:\(command.name)", kind: .slash, title: "/" + command.name,
                subtitle: command.description, keywords: command.aliases + [command.description],
                isEnabled: hasChat, disabledReason: hasChat ? nil : AppLocalization.string("No active chat"),
                confirmation: mode == .confirmThenRun ? MacPaletteSlashPolicy.confirmation(for: command) : nil,
                action: mode == .insert ? .insertSlash(command.name) : .runSlash(command.name)
            )
        }
    }

    private static func profileItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        (s.profiles.isEmpty ? [s.activeProfile] : s.profiles).map { name in
            let current = name == s.activeProfile
            return MacPaletteItem(
                id: "profile:\(name)", kind: .profile, title: name,
                subtitle: current ? AppLocalization.string("Current profile") : AppLocalization.string("Switch profile"),
                isEnabled: !current, isCurrent: current, action: .switchProfile(name)
            )
        }
    }

    private static func commandItems(_ s: MacPaletteSnapshot) -> [MacPaletteItem] {
        var list: [MacPaletteItem] = [
            MacPaletteItem(id: "command:newChat", kind: .command, title: AppLocalization.string("New Chat"),
                           keywords: ["create", "start", "conversation"], action: .newChat),
            MacPaletteItem(id: "command:settings", kind: .command, title: AppLocalization.string("Settings"),
                           keywords: ["preferences", "options"], action: .openSettings),
            MacPaletteItem(id: "command:toggleSidebar", kind: .command,
                           title: s.sidebarVisible ? AppLocalization.string("Hide Sidebar") : AppLocalization.string("Show Sidebar"),
                           keywords: ["sidebar", "panel", "toggle"], action: .toggleSidebar),
            MacPaletteItem(id: "command:searchSessions", kind: .command, title: AppLocalization.string("Search Sessions"),
                           keywords: ["find", "chats"], action: .searchSessions),
            MacPaletteItem(id: "command:checkForUpdates", kind: .command, title: AppLocalization.string("Check for Updates"),
                           keywords: ["upgrade", "version"], isEnabled: s.canCheckForUpdates,
                           disabledReason: s.canCheckForUpdates ? nil : AppLocalization.string("Updates are unavailable right now"),
                           action: .checkForUpdates),
            MacPaletteItem(id: "model:switch", kind: .model, title: AppLocalization.string("Switch Model..."),
                           keywords: ["model", "picker", "llm"], action: .openModelPicker),
        ]
        if s.isTurnRunning {
            list.append(MacPaletteItem(
                id: "command:stopResponse", kind: .command, title: AppLocalization.string("Stop Response"),
                keywords: ["cancel", "interrupt", "halt"],
                confirmation: MacPaletteConfirmation(
                    title: AppLocalization.string("Stop the current response?"),
                    message: AppLocalization.string("Text received so far stays in the chat."),
                    confirmTitle: AppLocalization.string("Stop")),
                action: .stopResponse))
        }
        list += SidebarTab.allCases.map { tab in
            MacPaletteItem(id: "pane:\(tab.rawValue)", kind: .pane, title: tab.displayName,
                           subtitle: AppLocalization.string("Pane"), keywords: ["pane", "tab", "go"], action: .selectPane(tab))
        }
        return list
    }

    // MARK: - Empty-query sections

    /// Recent (max 8, any kind), Commands (commands, model, panes, profiles),
    /// the active chat's slash commands collapsed to 5, then chats. A row
    /// shown in Recent is not repeated. Total rows capped at 50.
    static func sections(items: [MacPaletteItem], recents: [MacPaletteItem]) -> [MacPaletteSection] {
        let recent = Array(recents.prefix(MacPaletteRecents.shownLimit))
        let recentIDs = Set(recent.map(\.id))
        let rest = items.filter { !recentIDs.contains($0.id) }
        let commandKinds: Set<MacPaletteKind> = [.command, .model, .pane, .profile]
        var sections: [MacPaletteSection] = []
        func add(_ title: String, _ list: [MacPaletteItem]) {
            if !list.isEmpty { sections.append(MacPaletteSection(title: title, items: list)) }
        }
        add(AppLocalization.string("Recent"), recent)
        add(AppLocalization.string("Commands"), rest.filter { commandKinds.contains($0.kind) })
        add(AppLocalization.string("Slash Commands"), Array(rest.filter { $0.kind == .slash }.prefix(collapsedSlashCount)))
        add(AppLocalization.string("Chats"), rest.filter { $0.kind == .session })
        return capped(sections)
    }

    static func capped(_ sections: [MacPaletteSection], limit: Int = MacPaletteMatcher.rowLimit) -> [MacPaletteSection] {
        var remaining = limit
        var out: [MacPaletteSection] = []
        for section in sections where remaining > 0 {
            let take = Array(section.items.prefix(remaining))
            remaining -= take.count
            out.append(MacPaletteSection(title: section.title, items: take))
        }
        return out
    }
}
