import XCTest
import AppKit
import SwiftUI
@testable import ConduitMac

/// The Mac density pass: the sidebar and the pane-header buttons use desktop
/// sizes (32 pt controls, 24 pt chips, ~52 pt session rows) instead of the
/// iPad touch sizes upstream draws. The geometry tests read what SwiftUI lays
/// out through the accessibility tree (the tree the hover layer uses), in a
/// real window, so a reverted size goes red. The shot test is env-gated:
/// `TEST_RUNNER_CONDUIT_DENSITY_SHOTS=<directory>` writes PNGs there.
@MainActor
final class SidebarDensityTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var boostWasOn = false
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        boostWasOn = AccessibilityTreeBoost.isOn
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarDensityTests.\(UUID().uuidString)", isDirectory: true)
        appState = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        appState.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        appState.widgetSnapshotReloadOverride = {}
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
        // The voice button shows when the profile has voice on (no connection: the "disconnected" bucket).
        suite.defaults.set(true, forKey: "conduit.voice.enabled.v1.disconnected.\(appState.activeProfile)")
        // The sidebar tab key is @AppStorage on standard defaults; the strip tests rely on the default.
        appState.sessions = [
            summary("p1", "Weekly planning notes", model: "claude-opus-5", when: "2m ago"),
            summary("p2", "Salesforce deploy checklist", model: "gpt-5", when: "1h ago", source: .telegram),
            summary("r1", "Kanban density review", model: "claude-opus-5", when: "3h ago"),
            summary("r2", "Cron nightly digest", model: "claude-sonnet-5", when: "Yesterday", source: .discord),
            summary("r3", "Refactor the sync service for offline use", model: "claude-opus-5", when: "Tue"),
            summary("r4", "Voice call with the design team", model: "gemini-live", when: "Mon", source: .voice),
        ]
        appState.activeSessionId = "r1"
        appState.toggleSessionPinned(appState.sessions[0])
        appState.toggleSessionPinned(appState.sessions[1])
    }

    override func tearDown() async throws {
        AccessibilityTreeBoost.set(boostWasOn)
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func summary(_ id: String, _ title: String, model: String, when: String,
                         source: SessionSource = .chat) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: nil, alternateIds: [], title: title, model: model,
            updatedLabel: when, profile: appState.activeProfile, source: source, isActive: false,
            isArchived: false, lineageRootId: nil
        )
    }

    // MARK: - Hosting

    private func sidebar() -> some View {
        SidebarView(onRequestSettings: {}, presentation: .persistent)
            .environmentObject(appState)
    }

    private func host<V: View>(_ view: V, size: NSSize, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFront(nil)
        windows.append(window)
        HostedTestSupport.settle(0.6)
        return window
    }

    private func nodes(in window: NSWindow) throws -> [AccessibilityProbe.Node] {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let start = Date()
        while (window.contentView?.accessibilityChildren() ?? []).isEmpty, Date().timeIntervalSince(start) < 3 {
            HostedTestSupport.settle(0.01)
        }
        HostedTestSupport.settle(0.4)
        return AccessibilityProbe.nodes(in: window)
    }

    private func frame(_ label: String, in nodes: [AccessibilityProbe.Node], file: StaticString = #filePath,
                       line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(nodes.first { $0.label == label }?.frame,
                      "no node labelled \(label): \(nodes.compactMap(\.label))", file: file, line: line)
    }

    /// The "Manage sessions" Menu reports no label (a SwiftUI Menu is an AXMenuButton): it is the
    /// menu button between the voice and folder buttons.
    private func manageMenu(in nodes: [AccessibilityProbe.Node]) throws -> CGRect {
        let voice = try frame("New voice call", in: nodes)
        let folder = try frame("Browse projects", in: nodes)
        return try XCTUnwrap(nodes.first {
            $0.role == "AXMenuButton" && $0.frame.minX > voice.maxX - 0.5 && $0.frame.maxX < folder.minX + 0.5
                && abs($0.frame.midY - voice.midY) < 2
        }?.frame, "Manage sessions menu")
    }

    /// Row heights of the session list's table view (List is an NSOutlineView on macOS).
    private func sessionRowHeights(in window: NSWindow) throws -> [CGFloat] {
        func table(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews { if let t = table(in: sub) { return t } }
            return nil
        }
        let tableView = try XCTUnwrap(table(in: try XCTUnwrap(window.contentView)), "no table view")
        return (0..<tableView.numberOfRows).map { tableView.rect(ofRow: $0).height }
    }

    // MARK: - Geometry

    func testSidebarControlsAreThirtyTwoPoints() throws {
        let window = host(sidebar(), size: NSSize(width: 340, height: 900), dark: true)
        let found = try nodes(in: window)
        if ProcessInfo.processInfo.environment["CONDUIT_DENSITY_DUMP"] == "1" {
            for node in found { print("DENSITY-NODE \(node.role) \(node.label ?? "nil") \(node.frame)") }
        }
        for label in ["Settings", "Browse projects", "New voice call"] {
            let f = try frame(label, in: found)
            XCTAssertEqual(f.height, MacControlHeight.compact, accuracy: 0.6, "\(label) height")
            XCTAssertEqual(f.width, MacControlHeight.compact, accuracy: 0.6, "\(label) width")
        }
        let more = try manageMenu(in: found)
        XCTAssertEqual(more.height, MacControlHeight.compact, accuracy: 0.6, "Manage sessions height")
        XCTAssertEqual(more.width, MacControlHeight.compact, accuracy: 0.6, "Manage sessions width")
        XCTAssertEqual(try frame("New Chat", in: found).height, MacControlHeight.compact, accuracy: 0.6, "New Chat")
        let workspace = try XCTUnwrap(found.first { ($0.label ?? "").contains("Workspace") }?.frame, "Workspace pill")
        XCTAssertEqual(workspace.height, MacControlHeight.compact, accuracy: 0.6, "Workspace pill")
    }

    func testSidebarRowGapsAreTighterThanTheTouchLayout() throws {
        let window = host(sidebar(), size: NSSize(width: 340, height: 900), dark: true)
        let found = try nodes(in: window)
        let chat = try frame("New Chat", in: found)
        let voice = try frame("New voice call", in: found)
        let more = try manageMenu(in: found)
        let folder = try frame("Browse projects", in: found)
        XCTAssertEqual(voice.minX - chat.maxX, MacSidebarMetrics.rowGap, accuracy: 0.6)
        XCTAssertEqual(more.minX - voice.maxX, MacSidebarMetrics.rowGap, accuracy: 0.6)
        XCTAssertEqual(folder.minX - more.maxX, MacSidebarMetrics.rowGap, accuracy: 0.6)
        XCTAssertLessThan(MacSidebarMetrics.rowGap, 10)
    }

    func testTabStripIsThirtyTwoPoints() throws {
        let window = host(sidebar(), size: NSSize(width: 340, height: 900), dark: true)
        let found = try nodes(in: window)
        let tabs = try ["Sessions", "Bots", "Cron", "Kanban"].map { try frame($0, in: found) }
        for tab in tabs {
            XCTAssertEqual(tab.height, MacTabStripMetrics.segmentHeight, accuracy: 0.6)
            XCTAssertGreaterThanOrEqual(tab.height, 24, "hit target")
        }
        XCTAssertEqual(MacTabStripMetrics.containerHeight, 32)
        XCTAssertEqual(MacTabStripMetrics.segmentHeight, 26)
    }

    func testFilterChipsAreTwentyFourPoints() throws {
        let window = host(sidebar(), size: NSSize(width: 340, height: 900), dark: true)
        let found = try nodes(in: window)
        let chips = found.filter { ($0.label ?? "").hasPrefix("All ") || $0.label == "Status" || ($0.label ?? "").hasPrefix("Chat ") }
        XCTAssertGreaterThanOrEqual(chips.count, 2, "\(found.compactMap(\.label))")
        for chip in chips {
            XCTAssertEqual(chip.frame.height, MacSidebarMetrics.chipHeight, accuracy: 0.6, "\(chip.label ?? "")")
        }
    }

    func testSessionRowsAreCompact() throws {
        let window = host(sidebar(), size: NSSize(width: 340, height: 900), dark: true)
        let heights = try sessionRowHeights(in: window)
        if ProcessInfo.processInfo.environment["CONDUIT_DENSITY_DUMP"] == "1" { print("DENSITY-ROWS \(heights)") }
        // Two section headers (Pinned, Recent) and six session rows.
        let rows = heights.filter { $0 > 30 }
        XCTAssertEqual(rows.count, 6, "\(heights)")
        // Upstream's card measures 56 pt in the list; the Mac card must come in well under it.
        for height in rows {
            XCTAssertLessThanOrEqual(height, MacSidebarMetrics.sessionRowPitch, "row pitch \(heights)")
            XCTAssertGreaterThanOrEqual(height, MacSidebarMetrics.sessionRowPitch - 6, "row pitch \(heights)")
        }
    }

    func testPaneHeaderButtonsAreThirtyTwoPoints() throws {
        let window = host(KanbanView().environmentObject(appState), size: NSSize(width: 760, height: 300), dark: true)
        let found = try nodes(in: window)
        // Board menu, actions menu (no AX label), Select, Refresh, New: the five buttons in the header row.
        let buttons = found.filter {
            ($0.role == "AXButton" || $0.role == "AXMenuButton") && $0.frame.minY < 70
                && $0.label != "Search" && $0.label != "Open filters" && $0.frame.width < 60
        }
        XCTAssertEqual(buttons.count, 5, "\(found.map { "\($0.role) \($0.label ?? "nil") \($0.frame)" })")
        for button in buttons {
            XCTAssertEqual(button.frame.height, MacControlHeight.compact, accuracy: 0.6, "\(button.label ?? button.role)")
            XCTAssertEqual(button.frame.width, MacControlHeight.compact, accuracy: 0.6, "\(button.label ?? button.role)")
        }
    }

    // MARK: - Shots

    func testWriteShots() throws {
        guard let directory = ProcessInfo.processInfo.environment["CONDUIT_DENSITY_SHOTS"], !directory.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_CONDUIT_DENSITY_SHOTS=<directory> to write PNGs")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            let side = host(sidebar(), size: NSSize(width: 340, height: 900), dark: dark)
            try capture(side, to: "\(directory)/sidebar-\(name).png")
            let kanban = host(KanbanView().environmentObject(appState), size: NSSize(width: 760, height: 220), dark: dark)
            try capture(kanban, to: "\(directory)/kanban-header-\(name).png")
        }
    }

    /// `cacheDisplay` skips glass (the header rows and chips are drawn by the
    /// window server's glass layers), so the window is captured by id with
    /// `CGWindowListCreateImage` (looked up at run time: the SDK marks it
    /// unavailable). A process may capture its own windows without the
    /// screen-recording permission.
    private func capture(_ window: NSWindow, to path: String) throws {
        window.orderFrontRegardless()
        HostedTestSupport.settle(0.8)
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                                   "CGWindowListCreateImage is not available")
        let create = unsafeBitCast(symbol, to: Create.self)
        // optionIncludingWindow = 1 << 3, boundsIgnoreFraming = 1 << 0
        let image = try XCTUnwrap(create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                                  "window capture failed")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
