import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat a File > Export Chat... or Print Chat... command acts on (D32).
@MainActor
enum MacChatExportTarget {
    /// The main window, showing the open chat of `AppState`.
    case main
    /// A popped-out session window (D21), with its own transcript.
    case session(MacSessionWindowController)
}

/// Which session window shows which controller, so a menu action can find the transcript of the key window
/// (the way `MacSessionWindowStopRouter` finds its stop action). Weak on both sides.
@MainActor
final class MacChatExportSessions {
    static let shared = MacChatExportSessions()
    private struct Entry {
        weak var window: NSWindow?
        weak var controller: MacSessionWindowController?
    }
    private var entries: [Entry] = []

    /// Keeps the window's entry current. A nil controller drops it.
    func sync(window: NSWindow, controller: MacSessionWindowController?) {
        entries.removeAll { $0.window == nil || $0.controller == nil || $0.window === window }
        if let controller { entries.append(Entry(window: window, controller: controller)) }
    }

    func controller(for window: NSWindow?) -> MacSessionWindowController? {
        guard let window else { return nil }
        return entries.first { $0.window === window }?.controller
    }
}

/// The rule behind both menu items (D32). Pure apart from the window classification, so a test can
/// walk every case.
enum MacChatExportAvailability {
    enum Surface: Equatable { case main, session }

    /// The key window's surface. Nil when no command may act: no window, a sheet (or a window under one),
    /// a floating panel (Quick Ask), the Settings window, or any other window.
    @MainActor
    static func surface(of window: NSWindow?) -> Surface? {
        guard let window, !MacKeyboardActions.commandsBlocked(by: window) else { return nil }
        if MacSessionTabsActions.isMainChatWindow(window) { return .main }
        if MacSessionWindows.isSessionWindow(window) { return .session }
        return nil
    }

    /// `hasMessages` is about the chat of that surface: `AppState.messages` for the main window, the
    /// transcript for a session window.
    static func isAvailable(surface: Surface?, chatTabActive: Bool, roomOpen: Bool, hasMessages: Bool) -> Bool {
        switch surface {
        case nil: return false
        case .main: return chatTabActive && !roomOpen && hasMessages
        case .session: return hasMessages
        }
    }
}

/// The save panel and the failure alert (D32), behind a seam so tests never show one.
@MainActor
protocol MacChatExportPresenting {
    /// The file the user chose, or nil when they cancelled.
    func chooseDestination(suggestedName: String, window: NSWindow?) async -> URL?
    func showFailure(_ error: Error, window: NSWindow?)
}

/// The system panels. The save panel is a sheet on the chat window.
@MainActor
struct MacChatExportPanels: MacChatExportPresenting {
    static let markdownType: UTType =
        UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText

    func chooseDestination(suggestedName: String, window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.markdownType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = AppLocalization.string("Mac.ChatExport.SaveButton")
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    func showFailure(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Mac.ChatExport.WriteFailed")
        alert.informativeText = MacUntrustedText.sanitize(error.localizedDescription, maxGraphemes: 300)
        guard let window else { alert.runModal(); return }
        alert.beginSheetModal(for: window)
    }
}

/// Writes the export. UTF-8 without a byte order mark, in one atomic step, so a failed write leaves no half file.
enum MacChatExportWriter {
    static func write(_ markdown: String, to url: URL) throws {
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }
}

/// What File > Export Chat... (Cmd-Shift-E) and File > Print Chat... (Cmd-P) do (D32). Both act on the chat of
/// the key window and check again when they run: the menu is not rebuilt for every change of the key window.
@MainActor
enum MacChatExportActions {
    enum Outcome: Equatable {
        /// No chat shows in the key window, or a sheet or panel covers it.
        case unavailable
        case cancelled
        case written(URL)
        case failed
    }

    /// Where the commands act, or nil. The check reads `AppState` and the registry only; it builds nothing.
    static func target(
        window: NSWindow?, appState: AppState, tabRaw: String?, sessions: MacChatExportSessions? = nil
    ) -> MacChatExportTarget? {
        let surface = MacChatExportAvailability.surface(of: window)
        let controller = surface == .session ? (sessions ?? .shared).controller(for: window) : nil
        let hasMessages: Bool
        switch surface {
        case .main: hasMessages = !appState.messages.isEmpty
        case .session: hasMessages = !(controller?.transcript.messages.isEmpty ?? true)
        case nil: hasMessages = false
        }
        guard MacChatExportAvailability.isAvailable(
            surface: surface, chatTabActive: MacChatRoute.isChatActive(tabRaw: tabRaw),
            roomOpen: appState.activeRoomSurface != nil, hasMessages: hasMessages)
        else { return nil }
        if let controller { return .session(controller) }
        return surface == .main ? .main : nil
    }

    static func isAvailable(
        window: NSWindow?, appState: AppState, tabRaw: String?, sessions: MacChatExportSessions? = nil
    ) -> Bool {
        target(window: window, appState: appState, tabRaw: tabRaw, sessions: sessions) != nil
    }

    /// A copy of the chat as it is now.
    ///
    /// History (D32): the main window's chat loads in pages (`AppState.loadEarlierMessages`). That call is
    /// user-driven, single-flight, and moves what the reader sees, so the export does not call it. It exports
    /// the loaded rows, and `olderMessagesOmitted` follows `canLoadEarlierMessagesForActiveConversation`: the
    /// note under the title shows only when older pages exist. A session window reads the whole transcript
    /// with one `session.resume`, so nothing is omitted there.
    static func input(for target: MacChatExportTarget, appState: AppState) -> MacChatExportInput {
        switch target {
        case .main:
            return MacChatExportInput(
                title: appState.activeSessionTitle, agentName: appState.conversationAgentIdentity.name,
                messages: appState.messages, olderMessagesOmitted: appState.canLoadEarlierMessagesForActiveConversation)
        case .session(let controller):
            return MacChatExportInput(
                title: controller.title, agentName: appState.profileDisplayName(controller.token.profile),
                messages: controller.transcript.messages, olderMessagesOmitted: false)
        }
    }

    /// File > Export Chat...: the save panel, then the Markdown file. The optional parameters are for tests
    /// (a `.shared` or `.live` default trips Swift 6 isolation).
    @discardableResult
    static func export(
        window: NSWindow?, appState: AppState, tabRaw: String?, now: Date = Date(),
        sessions: MacChatExportSessions? = nil, presenter: (any MacChatExportPresenting)? = nil,
        strings: MacChatExportStrings? = nil, timeZone: TimeZone = .current,
        write: ((String, URL) throws -> Void)? = nil
    ) async -> Outcome {
        guard let target = target(window: window, appState: appState, tabRaw: tabRaw, sessions: sessions) else {
            return .unavailable
        }
        // The copy is taken now, so the file holds what the chat showed when the command ran.
        let input = input(for: target, appState: appState)
        let strings = strings ?? .live
        let presenter = presenter ?? MacChatExportPanels()
        let name = MacChatExportFileName.make(
            title: input.title, date: now, fallback: strings.fallbackTitle, timeZone: timeZone)
        guard let url = await presenter.chooseDestination(suggestedName: name, window: window) else { return .cancelled }
        do {
            let markdown = MacChatExport.markdown(input, exportedAt: now, strings: strings, timeZone: timeZone)
            try (write ?? MacChatExportWriter.write)(markdown, url)
            return .written(url)
        } catch {
            presenter.showFailure(error, window: window)
            return .failed
        }
    }

    /// File > Print Chat...: the system print panel. "Save as PDF" in that panel covers PDF.
    @discardableResult
    static func printChat(
        window: NSWindow?, appState: AppState, tabRaw: String?, now: Date = Date(),
        sessions: MacChatExportSessions? = nil, runner: (any MacChatPrintRunning)? = nil,
        strings: MacChatExportStrings? = nil, timeZone: TimeZone = .current
    ) -> Bool {
        guard let target = target(window: window, appState: appState, tabRaw: tabRaw, sessions: sessions) else { return false }
        let input = input(for: target, appState: appState)
        let strings = strings ?? .live
        let document = MacChatExport.document(input, exportedAt: now, strings: strings, timeZone: timeZone)
        let job = MacChatPrintJob(
            title: MacChatExportFileName.baseName(
                title: input.title, date: now, fallback: strings.fallbackTitle, timeZone: timeZone),
            content: MacChatPrintContent.attributedString(document, strings: strings))
        (runner ?? MacChatPrintRunner()).run(job, window: window)
        return true
    }
}

/// Keeps the two menu items current. `NSApp.keyWindow` is not an input SwiftUI tracks, and the menu is
/// not rebuilt when a sheet opens or closes, so this publishes after each change of the key window or of a
/// sheet. `ConduitCommands` observes it, so the items are disabled and enabled in step with the window. The
/// action checks again when it runs (`MacChatExportActions.target`), so a late rebuild cannot export the
/// wrong chat.
@MainActor
final class MacChatExportMenuState: ObservableObject {
    static let shared = MacChatExportMenuState()
    @Published private(set) var revision = 0
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // One turn later, so the window state has settled when the menu reads it.
                Task { @MainActor [weak self] in self?.revision &+= 1 }
            }
        }
    }

    deinit { observers.forEach(center.removeObserver) }
}
