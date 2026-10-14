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

    func testRendersInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = try host(store(3, active: 0), width: 700)
            window.appearance = NSAppearance(named: appearance)
            HostedTestSupport.settle()
            let content = try XCTUnwrap(window.contentView)
            let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: image)
            XCTAssertGreaterThan(image.pixelsWide, 0)
            HostedTestSupport.tearDown(window)
            self.window = nil
        }
    }

    // MARK: Toolbar width (D11)

    private struct ToolbarRoot: View {
        let store: MacSessionTabsStore
        var body: some View {
            NavigationSplitView {
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

    /// Hosts the chat toolbar's shape (sidebar toggle stand-in, strip, Refresh,
    /// status) at `width` and returns the platters left to right, in window coordinates.
    private func toolbarPlatters(width: CGFloat) throws -> [ToolbarPlatter] {
        guard #available(macOS 26.0, *) else { throw XCTSkip("system toolbar platters need macOS 26") }
        let controller = NSHostingController(rootView: ToolbarRoot(store: store(30, active: 29)))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: width, height: 400))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        if let previous = self.window { HostedTestSupport.tearDown(previous) }
        self.window = window
        HostedTestSupport.settle(1.0)
        return ToolbarPlatterGeometry.platters(in: window, near: window.frame)
            .map { ToolbarPlatter(frame: $0.frame.offsetBy(dx: -window.frame.minX, dy: 0), cornerRadius: $0.cornerRadius) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The principal slot does not grow into free space and an ideal wider
    /// than the room pushes Refresh into the overflow menu, so the strip sizes
    /// itself from the toolbar (MacToolbarSlotReader). At each width all four
    /// items stay on the toolbar and the strip fills at least 60% of the gap
    /// between the sidebar toggle and Refresh.
    func testStripFillsTheToolbarGapWithoutPushingItemsIntoOverflow() throws {
        for width in [1000, 1200, 1600] as [CGFloat] {
            let platters = try toolbarPlatters(width: width)
            XCTAssertEqual(platters.count, 4, "toggle, strip, Refresh and status all stay at \(width) pt: \(platters)")
            guard platters.count == 4 else { continue }
            let (toggle, tabs, refresh) = (platters[0].frame, platters[1].frame, platters[2].frame)
            let gap = refresh.minX - toggle.maxX
            XCTAssertGreaterThanOrEqual(tabs.width, gap * 0.6, "\(width) pt: strip \(tabs.width) of a \(gap) pt gap")
            XCTAssertLessThan(tabs.maxX, refresh.minX, "\(width) pt: strip clears Refresh")
        }
    }
}
