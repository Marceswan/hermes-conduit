import SwiftUI
import XCTest
@testable import ConduitMac

@MainActor
final class MacSessionTabStripTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var window: NSWindow?
    private var boostWasOn = false

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() async throws {
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        AccessibilityTreeBoost.set(boostWasOn)
        HostedTestSupport.dropSuite(suite)
    }

    private func store(_ count: Int, active: Int) -> MacSessionTabsStore {
        let store = MacSessionTabsStore(defaults: suite.defaults)
        store.setScope(dashboardID: nil, profile: "default")
        for i in 0..<count { store.activeSessionChanged("s\(i)", title: "Session number \(i)") }
        store.activeSessionChanged("s\(active)", title: "Session number \(active)")
        return store
    }

    private func strip(_ store: MacSessionTabsStore) -> some View {
        MacSessionTabStrip(store: store, onRename: { _ in }, onDelete: { _ in })
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
    }

    private func host(_ store: MacSessionTabsStore, width: CGFloat) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let window = HostedTestSupport.host(strip(store).frame(width: width, height: 44),
                                            size: NSSize(width: width, height: 44))
        self.window = window
        AccessibilityTreeBoost.set(true)
        return window
    }

    func testMetrics() {
        XCTAssertEqual(MacSessionTabMetrics.height, 28)
        XCTAssertEqual(MacSessionTabMetrics.minWidth, 120)
        XCTAssertEqual(MacSessionTabMetrics.maxWidth, 220)
    }

    func testEveryTabIsAnAccessibleButtonWithItsTitle() throws {
        let window = try host(store(3, active: 1), width: 900)
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.labels(in: window).contains("Session number 2")
        }, "\(AccessibilityProbe.labels(in: window))")
        let nodes = AccessibilityProbe.nodes(in: window)
        for i in 0..<3 {
            let node = try XCTUnwrap(nodes.first { $0.label == "Session number \(i)" })
            XCTAssertEqual(node.role, NSAccessibility.Role.button.rawValue)
            XCTAssertEqual(node.frame.height, MacSessionTabMetrics.height, accuracy: 0.6)
        }
    }

    func testPressingAnInactiveTabOpensItAndPressingTheActiveOneDoesNot() throws {
        let store = store(3, active: 1)
        var opened: [String] = []
        var scrolled = 0
        store.openSession = { opened.append($0) }
        store.scrollActiveToTop = { scrolled += 1 }
        let window = try host(store, width: 900)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: window).contains("Session number 2") })
        XCTAssertTrue(AccessibilityProbe.press("Session number 2", in: window))
        XCTAssertEqual(opened, ["s2"])
        XCTAssertTrue(AccessibilityProbe.press("Session number 1", in: window))
        XCTAssertEqual(opened, ["s2"], "the active tab is not reopened")
        XCTAssertEqual(scrolled, 1, "pressing the active tab scrolls the chat to the top")
    }

    func testActiveTabIsScrolledIntoViewWithManyTabs() throws {
        let window = try host(store(30, active: 29), width: 600)
        let bounds = try XCTUnwrap(window.contentView).bounds
        XCTAssertTrue(HostedTestSupport.waitUntil {
            AccessibilityProbe.frame(of: "Session number 29", in: window).map { bounds.contains($0) } ?? false
        }, "the active (last) tab is visible")
        let first = try XCTUnwrap(AccessibilityProbe.frame(of: "Session number 0", in: window))
        XCTAssertFalse(bounds.contains(first), "the first tab scrolled out of view")
    }

    func testActiveTabStaysInViewWhenTheStripGetsNarrower() throws {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        let window = HostedTestSupport.host(strip(store(30, active: 29)).frame(maxWidth: .infinity, maxHeight: 44),
                                            size: NSSize(width: 900, height: 44))
        self.window = window
        AccessibilityTreeBoost.set(true)
        func visible() -> Bool {
            guard let bounds = window.contentView?.bounds else { return false }
            return AccessibilityProbe.frame(of: "Session number 29", in: window).map { bounds.contains($0) } ?? false
        }
        XCTAssertTrue(HostedTestSupport.waitUntil { visible() }, "visible at 900 pt")
        window.setContentSize(NSSize(width: 400, height: 44))
        XCTAssertTrue(HostedTestSupport.waitUntil { visible() }, "still visible at 400 pt")
    }

    /// Active tab text against its accent fill, sampled from the rendered pixels
    /// (the darkest or lightest pixel in the tab against a fill pixel).
    private func activeTabContrast(in window: NSWindow) -> Double? {
        guard let tab = AccessibilityProbe.frame(of: "Session number 1", in: window),
              let content = window.contentView,
              let captured = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: captured)
        // The capture is in the display's colour space; contrast is defined on sRGB.
        guard let rep = captured.converting(to: .sRGB, renderingIntent: .default) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        func luminance(_ color: NSColor) -> Double? {
            // `converting(to: .sRGB)` already put the pixels in sRGB; the colour's tag is not trustworthy.
            let c = color
            func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        guard let fill = rep.colorAt(x: Int((tab.minX + 8) * scale), y: Int(tab.midY * scale)).flatMap(luminance) else { return nil }
        var best = 1.0
        for px in Int((tab.minX + 14) * scale)..<Int((tab.maxX - 14) * scale) {
            for py in Int((tab.minY + 4) * scale)..<Int((tab.maxY - 4) * scale) {
                guard let l = rep.colorAt(x: px, y: py).flatMap(luminance) else { continue }
                best = max(best, (max(l, fill) + 0.05) / (min(l, fill) + 0.05))
            }
        }
        return best
    }

    func testActiveTabTextHasAtLeast4_5ToOneContrastInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = try host(store(3, active: 1), width: 700)
            window.appearance = NSAppearance(named: appearance)
            var ratio = 0.0
            let reached = HostedTestSupport.waitUntil {
                ratio = self.activeTabContrast(in: window) ?? 0
                return ratio >= 4.5
            }
            XCTAssertTrue(reached, "\(appearance.rawValue): active tab contrast \(ratio):1")
            HostedTestSupport.tearDown(window)
            self.window = nil
        }
    }

    // MARK: Slot width (pure)

    private func platter(_ minX: CGFloat, _ width: CGFloat = 36) -> ToolbarPlatter {
        ToolbarPlatter(frame: CGRect(x: minX, y: 0, width: width, height: 36), cornerRadius: 18)
    }

    private func stripFrame(_ minX: CGFloat, _ width: CGFloat) -> CGRect { CGRect(x: minX, y: 0, width: width, height: 36) }

    /// Toggle, the strip (560...960) and three trailing items: Refresh, status, search.
    private var threeTrailing: [ToolbarPlatter] {
        [platter(300), platter(560, 400), platter(1100), platter(1144), platter(1188)]
    }

    func testAvailableWidthIsTheRoomBetweenTheTitleAreaAndTheNearestTrailingItem() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(560, 400), among: threeTrailing),
                       1100 - (500 + MacToolbarSlot.titleGap) - MacToolbarSlot.trailingMargin)
    }

    /// The count of trailing items does not matter: one, two, three or five give the same room.
    func testTheNumberOfTrailingItemsDoesNotChangeTheRoom() {
        let strip = stripFrame(560, 400)
        let expected = 1100 - (500 + MacToolbarSlot.titleGap) - MacToolbarSlot.trailingMargin
        for count in 1...5 {
            let platters = [platter(300), platter(560, 400)] + (0..<count).map { platter(1100 + CGFloat($0) * 44) }
            XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: strip, among: platters), expected, "\(count) trailing")
        }
    }

    /// The strip's own width is not an input: the same room at 120 pt and at 400 pt.
    func testTheRoomDoesNotDependOnTheStripsOwnWidth() {
        let trailing = [platter(1100), platter(1144)]
        let narrow = MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(656, 120), among: [platter(300), platter(656, 120)] + trailing)
        let wide = MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(504, 560), among: [platter(300), platter(504, 560)] + trailing)
        XCTAssertEqual(narrow, wide)
    }

    func testWithoutATitleAreaItMeasuresFromTheStripsOwnLeftEdge() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: nil, strip: stripFrame(561, 400), among: threeTrailing),
                       1100 - 561 - MacToolbarSlot.trailingMargin)
    }

    func testTrailingPlattersAreTheOnesRightOfTheStrip() {
        XCTAssertEqual(MacToolbarSlot.trailing(of: stripFrame(560, 400), among: threeTrailing).map(\.frame.minX), [1100, 1144, 1188])
        XCTAssertTrue(MacToolbarSlot.trailing(of: stripFrame(560, 400), among: [platter(300), platter(560, 400)]).isEmpty)
    }

    func testNothingTrailingTheStripShrinksToZero() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(560, 400), among: [platter(300), platter(560, 400)]), 0)
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(560, 400), among: []), 0)
    }

    func testAvailableWidthNeverGoesNegative() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: stripFrame(400, 100), among: [platter(510), platter(540)]), 0)
    }

    /// A search field (wider than a round button) can squeeze to a magnifier,
    /// so the optimistic room includes what it would free; round buttons free nothing.
    func testOptimisticRoomAddsWhatWideTrailingItemsCanGiveUp() {
        let platters = [platter(300), platter(560, 400), platter(1100), platter(1144), platter(1188, 249)]
        let strip = stripFrame(560, 400)
        let conservative = MacToolbarSlot.availableWidth(titleEnd: 500, strip: strip, among: platters)
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: strip, among: platters, optimistic: true),
                       conservative + (249 - MacToolbarSlot.roundPlatterWidth))
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, strip: strip, among: threeTrailing, optimistic: true),
                       MacToolbarSlot.availableWidth(titleEnd: 500, strip: strip, among: threeTrailing))
    }

    func testOverflowedItemsAreTheOnesMissingFromTheVisibleSetExceptSpacers() {
        XCTAssertEqual(MacToolbarSlot.overflowed(all: ["a", "NSToolbarFlexibleSpaceItem", "b", "c"], visible: ["a", "c"]), ["b"])
        XCTAssertEqual(MacToolbarSlot.overflowed(all: ["a", "NSToolbarSidebarTrackingSeparatorItem", "b"], visible: ["a", "b"]), [])
        XCTAssertEqual(MacToolbarSlot.overflowed(all: [], visible: []), [])
    }

    // MARK: Toolbar width (D11)

    @MainActor
    private final class SidebarModel: ObservableObject {
        @Published var visibility = NavigationSplitViewVisibility.all
        /// Whether the sidebar list carries `.searchable` (the window search item).
        @Published var searchPresent = true
    }

    private struct ToolbarRoot: View {
        let store: MacSessionTabsStore
        @ObservedObject var sidebar: SidebarModel
        @State private var query = ""

        /// With the window search item, as the real sessions list has (SidebarView).
        @ViewBuilder private var sidebarList: some View {
            if sidebar.searchPresent {
                List { Text("Sidebar") }.searchable(text: $query, prompt: "Search sessions")
            } else {
                List { Text("Sidebar") }
            }
        }

        var body: some View {
            NavigationSplitView(columnVisibility: $sidebar.visibility) {
                sidebarList
                    .navigationSplitViewColumnWidth(min: 340, ideal: 340, max: 340)
            } detail: {
                NavigationStack {
                    Color.clear
                        .navigationTitle("")
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button {} label: { Image(systemName: "sidebar.leading") }
                                    .accessibilityLabel("Toggle sidebar stand-in")
                            }
                            ToolbarItem(placement: .principal) {
                                MacSessionTabStrip(store: store, onRename: { _ in }, onDelete: { _ in })
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button {} label: { Image(systemName: "arrow.clockwise") }
                                    .accessibilityLabel("Refresh conversation")
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button {} label: { Circle().fill(.green).frame(width: 9, height: 9) }
                                    .accessibilityLabel("Gateway connected")
                            }
                        }
                }
            }
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
        }
    }

    private func hostToolbar(width: CGFloat, sidebar: SidebarModel? = nil) throws -> NSWindow {
        guard #available(macOS 26.0, *) else { throw XCTSkip("system toolbar platters need macOS 26") }
        let controller = NSHostingController(rootView: ToolbarRoot(store: store(30, active: 29), sidebar: sidebar ?? SidebarModel()))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: width, height: 400))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if let previous = self.window { HostedTestSupport.tearDown(previous) }
        self.window = window
        return window
    }

    /// What the toolbar shows right now: every platter (window coordinates,
    /// left to right) and which toolbar items sit on the toolbar or in the
    /// overflow menu. Spacers and separators are not items.
    private struct ToolbarSnapshot: Equatable, CustomStringConvertible {
        var platters: [ToolbarPlatter]
        var visible: [String]
        var hidden: [String]

        var itemCount: Int { visible.count + hidden.count }
        var description: String {
            "platters \(platters.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }), visible \(visible.count), in overflow \(hidden.count)"
        }
    }

    private func snapshot(of window: NSWindow) -> ToolbarSnapshot {
        let platters = ToolbarPlatterGeometry.platters(in: window, near: window.frame)
            .map { ToolbarPlatter(frame: $0.frame.offsetBy(dx: -window.frame.minX, dy: 0), cornerRadius: $0.cornerRadius) }
            .sorted { $0.frame.minX < $1.frame.minX }
        func isSpacer(_ item: NSToolbarItem) -> Bool { item.itemIdentifier.rawValue.hasPrefix("NSToolbar") }
        let all = (window.toolbar?.items ?? []).filter { !isSpacer($0) }
        let shown = Set((window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        return ToolbarSnapshot(platters: platters,
                               visible: all.filter { shown.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue),
                               hidden: all.filter { !shown.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue))
    }

    /// Waits for the toolbar to go quiet (no change for 0.5 s; a first layout
    /// and the search item collapsing take a few turns, the flicker never goes
    /// quiet), then asserts every toolbar item is on a platter, none in the
    /// overflow menu, the strip is clear of the item after it and fills at
    /// least `minRatio` of the gap between the toggle and that item, and then
    /// that the platters and the visible set stay put for `watch` seconds.
    @discardableResult
    private func expectSteadyToolbar(in window: NSWindow, _ step: String, minRatio: CGFloat = 0, watch: TimeInterval = 1.0,
                                     file: StaticString = #filePath, line: UInt = #line) -> ToolbarSnapshot {
        var latest = snapshot(of: window)
        var changedAt = Date()
        let quiet = HostedTestSupport.waitUntil(timeout: 4) {
            let now = snapshot(of: window)
            if now != latest { latest = now; changedAt = Date() }
            return Date().timeIntervalSince(changedAt) >= 0.5
        }
        XCTAssertTrue(quiet, "\(step): the toolbar never went quiet; now \(latest)", file: file, line: line)
        XCTAssertTrue(latest.hidden.isEmpty, "\(step): no toolbar item in the overflow menu; now \(latest)", file: file, line: line)
        XCTAssertEqual(latest.platters.count, latest.itemCount, "\(step): one platter per toolbar item; now \(latest)", file: file, line: line)
        if latest.platters.count >= 3 {
            let platters = latest.platters
            XCTAssertLessThan(platters[1].frame.maxX, platters[2].frame.minX, "\(step): the strip clear of the next item; now \(latest)", file: file, line: line)
            let gap = platters[2].frame.minX - platters[0].frame.maxX
            XCTAssertGreaterThanOrEqual(platters[1].frame.width, max(MacSessionTabMetrics.minWidth, gap * minRatio) - 1,
                                        "\(step): the strip fills at least \(minRatio) of the toggle-to-next-item gap; now \(latest)", file: file, line: line)
        }
        var seen = [snapshot(of: window)]
        let end = Date().addingTimeInterval(watch)
        while Date() < end {
            HostedTestSupport.settle(0.025)
            let now = snapshot(of: window)
            if now != seen.last { seen.append(now) }
        }
        XCTAssertEqual(seen.count, 1, "\(step): the toolbar changed while it should be still: \(seen.map(\.description))", file: file, line: line)
        return latest
    }

    /// The principal slot does not grow into free space and an ideal wider
    /// than the room pushes Refresh into the overflow menu, so the strip sizes
    /// itself from the toolbar (MacToolbarSlotReader). At each width all four
    /// items stay on the toolbar and the strip fills at least 60% of the gap
    /// between the sidebar toggle and Refresh.
    func testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow() throws {
        for width in [1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width)
            expectSteadyToolbar(in: window, "\(width) pt", minRatio: 0.6)
        }
    }

    /// One window through the sizes and the sidebar changes a user makes: the
    /// stale ideal after a shrink must not leave Refresh in the overflow menu.
    /// 820 is the window's minimum width (MacSidebarState.windowMinWidth).
    func testToolbarKeepsAllItemsThroughResizeAndSidebarToggle() throws {
        let sidebar = SidebarModel()
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        expectSteadyToolbar(in: window, "1200 pt", minRatio: 0.6)

        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        let narrow = expectSteadyToolbar(in: window, "820 pt (the window minimum)")
        XCTAssertGreaterThanOrEqual(narrow.platters[1].frame.width, MacSessionTabMetrics.minWidth, "the strip keeps its minimum")

        window.setContentSize(NSSize(width: 1400, height: 400))
        expectSteadyToolbar(in: window, "1400 pt", minRatio: 0.6)

        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "sidebar hidden", minRatio: 0.6)

        sidebar.visibility = .all
        expectSteadyToolbar(in: window, "sidebar shown again", minRatio: 0.6)
    }

    /// The live toolbar has a third trailing item, the window search item
    /// `.searchable` puts there (a magnifier when narrow). The strip must
    /// leave room for all of them and must not flicker at any width.
    func testNoTrailingItemIsPushedIntoOverflowAndTheToolbarDoesNotFlicker() throws {
        for width in [820, 1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width)
            XCTAssertEqual(snapshot(of: window).itemCount, 5, "toggle, strip, Refresh, status and the search item")
            expectSteadyToolbar(in: window, "\(width) pt", minRatio: width == 820 ? 0 : 0.6)
        }
    }

    /// The same through the sidebar hiding and showing (the search item lives
    /// in the sidebar column; it may leave the toolbar with it).
    func testToolbarDoesNotFlickerThroughSidebarHideAndShow() throws {
        let sidebar = SidebarModel()
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        expectSteadyToolbar(in: window, "sidebar shown")
        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "sidebar hidden")
        sidebar.visibility = .all
        expectSteadyToolbar(in: window, "sidebar shown again")
        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        expectSteadyToolbar(in: window, "820 pt")
        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "820 pt, sidebar hidden")
    }

    /// The search item may come and go (the sidebar column owns it): the
    /// strip counts no items, so one fewer or one more is nothing special.
    func testToolbarDoesNotFlickerWhenTheSearchItemComesAndGoes() throws {
        let sidebar = SidebarModel()
        sidebar.searchPresent = false
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        let without = expectSteadyToolbar(in: window, "without the search item", minRatio: 0.6)
        XCTAssertEqual(without.itemCount, 4, "toggle, strip, Refresh, status")
        sidebar.searchPresent = true
        let with = expectSteadyToolbar(in: window, "search item added", minRatio: 0.6)
        XCTAssertEqual(with.itemCount, 5)
        sidebar.searchPresent = false
        expectSteadyToolbar(in: window, "search item removed", minRatio: 0.6)
        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        expectSteadyToolbar(in: window, "820 pt without the search item")
    }
}
