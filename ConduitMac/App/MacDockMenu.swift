import AppKit

/// What each Dock menu item does, as plain closures so tests inject fakes (as `MacHomeActions` does).
struct MacDockMenuActions {
    var newChat: @MainActor () -> Void
    var quickAsk: @MainActor () -> Void
    var openSession: @MainActor (String) -> Void
    var openConduit: @MainActor () -> Void

    /// New Chat and an open session bring Conduit forward first. Quick Ask does not: its panel never activates
    /// Conduit (D15), so the main window stays where it is behind the user's own app.
    @MainActor
    static func live(
        appState: AppState,
        bringForward: @escaping @MainActor () -> Void = { MacWindowActivation.bringConduitForward() },
        showQuickAsk: @escaping @MainActor () -> Void = { MacQuickAskController.shared.show() }
    ) -> MacDockMenuActions {
        let home = MacHomeActions.live(appState: appState)
        return MacDockMenuActions(
            // The File > New Chat path (Ruling R39): during the connect it queues one chat. `window: nil`
            // because `bringForward` has already dealt with the main window.
            newChat: { [weak appState] in
                bringForward()
                if let appState { MacAppActions.newChat(window: nil, appState: appState) }
            },
            quickAsk: showQuickAsk,
            // Home's route: the sidebar row's `requestOpenSession` with the catalog id.
            openSession: { id in
                bringForward()
                home.openSession(id)
            },
            openConduit: bringForward
        )
    }
}

extension MacDockSnapshot {
    /// The menu's input: what Home lists (the feed's rows, the active profile's chats that are not archived).
    @MainActor
    static func make(appState: AppState, feed: AgentActivityFeed?, now: Date) -> MacDockSnapshot {
        let input = MacHomeBinding.input(appState: appState, feed: feed, kanban: .notLoaded, cron: .notLoaded, now: now)
        return MacDockSnapshot(feed: input.feed, live: input.live, sessions: input.sessions)
    }
}

/// The menu for a right-click on the Dock icon (D31): New Chat, Quick Ask, the chats that need the user, the recent chats.
@MainActor
enum MacDockMenu {
    /// Built fresh on each right-click (AppKit asks the delegate every time).
    static func make(appState: AppState) -> NSMenu {
        let snapshot = MacDockSnapshot.make(appState: appState, feed: AgentActivityFeed.shared, now: Date())
        return menu(for: MacDockContent.entries(snapshot), actions: .live(appState: appState))
    }

    static func menu(for entries: [MacDockEntry], actions: MacDockMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                menu.addItem(MacDockActionItem(title: item.title) { run(item.action, with: actions) })
            }
        }
        return menu
    }

    private static func run(_ action: MacDockItem.Action, with actions: MacDockMenuActions) {
        switch action {
        case .newChat: actions.newChat()
        case .quickAsk: actions.quickAsk()
        case .openSession(let id): actions.openSession(id)
        case .openConduit: actions.openConduit()
        }
    }
}

/// A menu item that runs a closure. It is its own target: `NSMenuItem.target` is weak, and nothing else
/// would keep a separate target alive while the Dock shows the menu.
@MainActor
private final class MacDockActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("MacDockActionItem is not decoded")
    }

    @objc private func fire() { handler() }
}
