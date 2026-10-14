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

    func testAvailableWidthIsTheRoomBetweenTheTitleAreaAndTheFirstTrailingItem() {
        let platters = [platter(300), platter(560, 400), platter(1100), platter(1144)]
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, ownMinX: 560, among: platters),
                       1100 - (500 + MacToolbarSlot.titleGap) - MacToolbarSlot.trailingMargin)
    }

    func testWithoutATitleAreaItMeasuresFromTheStripsOwnLeftEdge() {
        let platters = [platter(300), platter(560, 400), platter(1100), platter(1144)]
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: nil, ownMinX: 561, among: platters),
                       1100 - 561 - MacToolbarSlot.trailingMargin)
    }

    func testNothingToMeasureFromIsNil() {
        XCTAssertNil(MacToolbarSlot.availableWidth(titleEnd: nil, ownMinX: nil, among: [platter(1100), platter(1144)]))
    }

    func testTooFewTrailingPlattersShrinksToZero() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, ownMinX: 560, among: [platter(300)]), 0, "none")
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, ownMinX: 560, among: [platter(300), platter(1144)]), 0, "one")
    }

    /// Refresh in the overflow menu: the strip and the status dot are the two
    /// rightmost platters. The status dot's room must not be taken as the
    /// strip's, or the strip would keep Refresh out.
    func testWithRefreshInOverflowTheStripShrinksToItsOwnLeftEdge() {
        let platters = [platter(300), platter(560, 400), platter(1144)]
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, ownMinX: 560, among: platters),
                       560 - (500 + MacToolbarSlot.titleGap) - MacToolbarSlot.trailingMargin)
    }

    func testAvailableWidthNeverGoesNegative() {
        XCTAssertEqual(MacToolbarSlot.availableWidth(titleEnd: 500, ownMinX: 560, among: [platter(510), platter(540)]), 0)
    }

    // MARK: Toolbar width (D11)

    @MainActor
    private final class SidebarModel: ObservableObject {
        @Published var visibility = NavigationSplitViewVisibility.all
    }

    private struct ToolbarRoot: View {
        let store: MacSessionTabsStore
        @ObservedObject var sidebar: SidebarModel
        var body: some View {
            NavigationSplitView(columnVisibility: $sidebar.visibility) {
                List { Text("Sidebar") }
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

    /// Toggle, strip, Refresh and status on platters, left to right, in window
    /// coordinates; nil while fewer than four are there or the strip overlaps Refresh.
    private func settledPlatters(in window: NSWindow, minRatio: CGFloat) -> [ToolbarPlatter]? {
        let platters = ToolbarPlatterGeometry.platters(in: window, near: window.frame)
            .map { ToolbarPlatter(frame: $0.frame.offsetBy(dx: -window.frame.minX, dy: 0), cornerRadius: $0.cornerRadius) }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard platters.count == 4, platters[1].frame.maxX < platters[2].frame.minX else { return nil }
        let gap = platters[2].frame.minX - platters[0].frame.maxX
        return platters[1].frame.width >= max(MacSessionTabMetrics.minWidth, gap * minRatio) - 1 ? platters : nil
    }

    /// Polls until the toolbar shows all four items with the strip clear of Refresh.
    private func expectFourItems(in window: NSWindow, _ step: String, minRatio: CGFloat = 0.6, file: StaticString = #filePath, line: UInt = #line) -> [ToolbarPlatter]? {
        var found: [ToolbarPlatter]?
        let settled = HostedTestSupport.waitUntil { found = settledPlatters(in: window, minRatio: minRatio); return found != nil }
        let now = ToolbarPlatterGeometry.platters(in: window, near: window.frame).map { $0.frame.offsetBy(dx: -window.frame.minX, dy: 0) }
        XCTAssertTrue(settled, "\(step): toggle, strip (at least \(minRatio) of the toggle-to-Refresh gap, and 120 pt), Refresh and status on platters, strip clear of Refresh; platters now \(now)", file: file, line: line)
        return found
    }

    /// The principal slot does not grow into free space and an ideal wider
    /// than the room pushes Refresh into the overflow menu, so the strip sizes
    /// itself from the toolbar (MacToolbarSlotReader). At each width all four
    /// items stay on the toolbar and the strip fills at least 60% of the gap
    /// between the sidebar toggle and Refresh.
    func testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow() throws {
        for width in [1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width)
            _ = expectFourItems(in: window, "\(width) pt")
        }
    }

    /// One window through the sizes and the sidebar changes a user makes: the
    /// stale ideal after a shrink must not leave Refresh in the overflow menu.
    /// 820 is the window's minimum width (MacSidebarState.windowMinWidth).
    func testToolbarKeepsAllItemsThroughResizeAndSidebarToggle() throws {
        let sidebar = SidebarModel()
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        _ = expectFourItems(in: window, "1200 pt")

        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        let narrow = expectFourItems(in: window, "820 pt (the window minimum)", minRatio: 0)
        XCTAssertGreaterThanOrEqual(narrow?[1].frame.width ?? 0, MacSessionTabMetrics.minWidth, "the strip keeps its minimum")

        window.setContentSize(NSSize(width: 1400, height: 400))
        _ = expectFourItems(in: window, "1400 pt")

        sidebar.visibility = .detailOnly
        _ = expectFourItems(in: window, "sidebar hidden")

        sidebar.visibility = .all
        _ = expectFourItems(in: window, "sidebar shown again")
    }
}
