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

    func testIdealWidthIsTheWindowLessTheLeadingSpaceAndTheTrailingReserve() {
        // Measured in the hosted harness on macOS 27 (strip platter width, all five items visible).
        XCTAssertEqual(MacToolbarSlot.trailingReserve, 156)
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: 1200, sidebarWidth: 340), 492)
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: 1400, sidebarWidth: 340), 692)
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: 1200, sidebarWidth: 0), 744, "sidebar hidden: starts after the traffic lights")
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: 1200, sidebarWidth: 390), 1200 - 390 - 212 - 156)
    }

    func testIdealWidthIsMonotonicInTheWindowWidthAndNeverBelowTheMinimumOrNegative() {
        for sidebar in [0, 260, 340, 390] as [CGFloat] {
            var previous: CGFloat = 0
            for width in stride(from: 0 as CGFloat, through: 4000, by: 7) {
                let ideal = MacToolbarSlot.idealWidth(windowWidth: width, sidebarWidth: sidebar)
                XCTAssertGreaterThanOrEqual(ideal, MacSessionTabMetrics.minWidth, "window \(width), sidebar \(sidebar)")
                XCTAssertGreaterThanOrEqual(ideal, previous, "non-decreasing: window \(width), sidebar \(sidebar)")
                previous = ideal
            }
        }
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: -50, sidebarWidth: 340), MacSessionTabMetrics.minWidth)
        XCTAssertEqual(MacToolbarSlot.idealWidth(windowWidth: 820, sidebarWidth: 340), MacSessionTabMetrics.minWidth)
    }

    /// A wider sidebar leaves the strip less room; hiding it leaves the most.
    func testIdealWidthShrinksWithTheSidebarAndGrowsWhenItIsHidden() {
        let widths = [260, 340, 390, 0].map { MacToolbarSlot.idealWidth(windowWidth: 1400, sidebarWidth: $0) }
        XCTAssertGreaterThan(widths[3], widths[0])
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
    }

    // MARK: Toolbar width (D11)

    @MainActor
    private final class SidebarModel: ObservableObject {
        @Published var visibility = NavigationSplitViewVisibility.all
        /// Whether the sidebar list carries `.searchable` (the window search item).
        @Published var searchPresent = true
        /// A rigid extra trailing toolbar item of this width, beyond Refresh, the status dot and the search item.
        @Published var extraTrailingWidth: CGFloat?
        let sidebarWidth: CGFloat
        init(sidebarWidth: CGFloat = 340) { self.sidebarWidth = sidebarWidth }
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
                    .navigationSplitViewColumnWidth(min: sidebar.sidebarWidth, ideal: sidebar.sidebarWidth, max: sidebar.sidebarWidth)
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
                            if let width = sidebar.extraTrailingWidth {
                                ToolbarItem(placement: .primaryAction) {
                                    Button {} label: { Color.orange.frame(width: width, height: 12) }
                                        .accessibilityLabel("Extra trailing item")
                                }
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

    private typealias ToolbarSnapshot = ToolbarStability.Snapshot

    private func snapshot(of window: NSWindow) -> ToolbarSnapshot { ToolbarStability.snapshot(of: window) }

    /// See `ToolbarStability.expectSteady`.
    @discardableResult
    private func expectSteadyToolbar(in window: NSWindow, _ step: String, minRatio: CGFloat = 0, idealWidth: CGFloat? = nil,
                                     allowOverflow: Bool = false, watch: TimeInterval = 1.0,
                                     file: StaticString = #filePath, line: UInt = #line) -> ToolbarSnapshot {
        ToolbarStability.expectSteady(in: window, step, minRatio: minRatio, idealWidth: idealWidth,
                                      allowOverflow: allowOverflow, watch: watch, file: file, line: line)
    }

    /// The ideal width the strip should have in `window` with a sidebar of `sidebar` points.
    private func ideal(_ window: NSWindow, sidebar: CGFloat) -> CGFloat {
        MacToolbarSlot.idealWidth(windowWidth: window.frame.width, sidebarWidth: sidebar)
    }

    /// The principal slot does not grow into free space and an ideal wider
    /// than the room pushes trailing items into the overflow menu, so the strip
    /// is given the window's width less a reserve (MacToolbarSlot). At each
    /// width all five items stay on the toolbar, the strip is its ideal width
    /// and fills at least 60% of the gap between the sidebar toggle and Refresh.
    func testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow() throws {
        for width in [1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width)
            expectSteadyToolbar(in: window, "\(width) pt", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
        }
    }

    /// One window through the sizes and the sidebar changes a user makes: the
    /// stale ideal after a shrink must not leave Refresh in the overflow menu.
    /// 820 is the window's minimum width (MacSidebarState.windowMinWidth).
    func testToolbarKeepsAllItemsThroughResizeAndSidebarToggle() throws {
        let sidebar = SidebarModel()
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        expectSteadyToolbar(in: window, "1200 pt", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))

        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        let narrow = expectSteadyToolbar(in: window, "820 pt (the window minimum)")
        XCTAssertGreaterThanOrEqual(narrow.platters[1].frame.width, MacSessionTabMetrics.minWidth, "the strip keeps its minimum")

        window.setContentSize(NSSize(width: 1400, height: 400))
        expectSteadyToolbar(in: window, "1400 pt", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))

        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "sidebar hidden", minRatio: 0.6, idealWidth: ideal(window, sidebar: 0))

        sidebar.visibility = .all
        expectSteadyToolbar(in: window, "sidebar shown again", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
    }

    /// The live toolbar has a third trailing item, the window search item
    /// `.searchable` puts there (a magnifier when narrow). The reserve covers
    /// all of them: nothing in overflow, nothing flickering, at any width.
    func testNoTrailingItemIsPushedIntoOverflowAndTheToolbarDoesNotFlicker() throws {
        for width in [820, 1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width)
            XCTAssertEqual(snapshot(of: window).itemCount, 5, "toggle, strip, Refresh, status and the search item")
            expectSteadyToolbar(in: window, "\(width) pt", minRatio: width == 820 ? 0 : 0.6, idealWidth: ideal(window, sidebar: 340))
        }
    }

    /// The widest sidebar (390 pt, MacSidebarState.sidebarMaxWidth): all items
    /// stay at 1000 pt and wider, and hiding and showing the sidebar keeps them
    /// there. At 820 pt the 390 pt sidebar leaves 430 pt (the detail minimum),
    /// less than the toggle, the 120 pt strip and the reserve need, so an item
    /// goes to overflow whatever the strip does; the toolbar must still be still.
    func testToolbarStaysWholeAndSteadyAtTheSidebarMaximum() throws {
        for width in [1000, 1200, 1600] as [CGFloat] {
            let window = try hostToolbar(width: width, sidebar: SidebarModel(sidebarWidth: 390))
            expectSteadyToolbar(in: window, "\(width) pt, 390 pt sidebar", idealWidth: ideal(window, sidebar: 390))
        }
        let sidebar = SidebarModel(sidebarWidth: 390)
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        expectSteadyToolbar(in: window, "1200 pt, 390 pt sidebar", idealWidth: ideal(window, sidebar: 390))
        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "sidebar hidden", idealWidth: ideal(window, sidebar: 0))
        sidebar.visibility = .all
        expectSteadyToolbar(in: window, "sidebar shown again", idealWidth: ideal(window, sidebar: 390))
        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        expectSteadyToolbar(in: window, "820 pt, 390 pt sidebar", allowOverflow: true)
        sidebar.visibility = .detailOnly
        expectSteadyToolbar(in: window, "820 pt, sidebar hidden", idealWidth: ideal(window, sidebar: 0))
        sidebar.visibility = .all
        expectSteadyToolbar(in: window, "820 pt, 390 pt sidebar again", allowOverflow: true)
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

    /// The search item may come and go (the sidebar column owns it) and the
    /// width does not read the toolbar, so one item more or less changes nothing.
    func testToolbarDoesNotFlickerWhenTheSearchItemComesAndGoes() throws {
        let sidebar = SidebarModel()
        sidebar.searchPresent = false
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        let without = expectSteadyToolbar(in: window, "without the search item", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
        XCTAssertEqual(without.itemCount, 4, "toggle, strip, Refresh, status")
        sidebar.searchPresent = true
        let with = expectSteadyToolbar(in: window, "search item added", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
        XCTAssertEqual(with.itemCount, 5)
        sidebar.searchPresent = false
        expectSteadyToolbar(in: window, "search item removed", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
        window.setContentSize(NSSize(width: MacSidebarState.windowMinWidth, height: 400))
        expectSteadyToolbar(in: window, "820 pt without the search item")
    }

    /// The reserve's limit (documented on MacToolbarSlot): a fourth, rigid
    /// trailing item beyond Refresh, the dot and the search item does not fit,
    /// so something goes to the overflow menu, and the strip does not give way
    /// (its width does not read the toolbar). What must hold is that the
    /// toolbar is still, with and without the item, and that taking the item
    /// away brings every item back.
    func testAnExtraWideTrailingItemOverflowsButNothingFlickers() throws {
        let sidebar = SidebarModel()
        sidebar.extraTrailingWidth = 120
        let window = try hostToolbar(width: 1200, sidebar: sidebar)
        let crowded = expectSteadyToolbar(in: window, "extra 120 pt trailing item", allowOverflow: true)
        XCTAssertEqual(crowded.itemCount, 6, "toggle, strip, Refresh, status, extra, search")
        XCTAssertFalse(crowded.hidden.isEmpty, "the reserve is for three trailing items; a fourth wide one overflows: \(crowded)")
        window.setContentSize(NSSize(width: 1500, height: 400))
        expectSteadyToolbar(in: window, "extra item, 1500 pt", allowOverflow: true)
        sidebar.extraTrailingWidth = nil
        let whole = expectSteadyToolbar(in: window, "extra item removed", minRatio: 0.6, idealWidth: ideal(window, sidebar: 340))
        XCTAssertEqual(whole.itemCount, 5)
    }

    // MARK: Busy dot

    /// A repeating animation started with `withAnimation` also takes any other
    /// change in the same update. The busy dot's pulse did that in the toolbar:
    /// the whole tab row swung up and left and back, every 1.8 s, for as long as
    /// the chat worked. A repeat goes on the one attribute it pulses
    /// (`.animation(_:body:)`), never on a whole transaction.
    func testNoRepeatingAnimationStartsWithWithAnimation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["ConduitMac", "Conduit"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, dir)
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                var rest = source[...]
                while let call = rest.range(of: "withAnimation(") {
                    // The call's argument list, to its closing parenthesis.
                    var depth = 1
                    var end = call.upperBound
                    while end < rest.endIndex, depth > 0 {
                        if rest[end] == "(" { depth += 1 } else if rest[end] == ")" { depth -= 1 }
                        end = rest.index(after: end)
                    }
                    if rest[call.upperBound..<end].contains("repeatForever") {
                        offenders.append("\(dir)/\(file.lastPathComponent): \(rest[call.lowerBound..<end])")
                    }
                    rest = rest[end...]
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
