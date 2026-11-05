import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// A new accent pick in Settings redraws a hosted Mac scene at once (#697, #702, #750). The Mac dynamic accent colour
/// reads `UserDefaults`, which SwiftUI cannot observe by itself; `macAccentEnvironment()` makes the scene root depend
/// on the pick.
@MainActor
final class MacAccentEnvironmentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The accent colour and `@AppStorage` read the standard defaults, so the pick is the user's own key:
        // put it back (value or absence) when the test ends.
        preserveStandardDefaults(ConduitAccentChoice.storageKey)
    }

    /// Draws `Color.conduitAccent`, the colour almost every accented view uses.
    private struct AccentSwatch: View {
        var body: some View {
            Rectangle().fill(Color.conduitAccent).frame(width: 40, height: 40)
        }
    }

    private func centerColor(of window: NSWindow) -> NSColor? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    /// What a plain swatch of the pick's own colour reads as through the same hosting and capture path, so the
    /// comparison does not depend on colour management.
    private func reference(for choice: ConduitAccentChoice, dark: Bool = false) -> NSColor? {
        let window = HostedTestSupport.host(
            Rectangle().fill(Color(nsColor: choice.color(dark: dark))).frame(width: 40, height: 40),
            size: NSSize(width: 40, height: 40)
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { HostedTestSupport.tearDown(window) }
        HostedTestSupport.settle(0.1)
        return centerColor(of: window)
    }

    private func matches(_ actual: NSColor?, _ choice: ConduitAccentChoice, dark: Bool = false) -> Bool {
        guard let actual, let expected = reference(for: choice, dark: dark) else { return false }
        return abs(actual.redComponent - expected.redComponent) < 0.02
            && abs(actual.greenComponent - expected.greenComponent) < 0.02
            && abs(actual.blueComponent - expected.blueComponent) < 0.02
    }

    func testANewPickRedrawsTheSceneRootAtOnce() throws {
        UserDefaults.standard.set(ConduitAccentChoice.amber.rawValue, forKey: ConduitAccentChoice.storageKey)
        let window = HostedTestSupport.host(AccentSwatch().macAccentEnvironment(), size: NSSize(width: 40, height: 40))
        window.appearance = NSAppearance(named: .aqua)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { matches(centerColor(of: window), .amber) }, "amber first")

        UserDefaults.standard.set(ConduitAccentChoice.blue.rawValue, forKey: ConduitAccentChoice.storageKey)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { matches(centerColor(of: window), .blue) },
                      "the swatch kept the old pick: \(String(describing: centerColor(of: window)))")
    }

    func testANewPickRedrawsInDarkAppearance() throws {
        UserDefaults.standard.set(ConduitAccentChoice.amber.rawValue, forKey: ConduitAccentChoice.storageKey)
        let window = HostedTestSupport.host(AccentSwatch().macAccentEnvironment(), size: NSSize(width: 40, height: 40))
        window.appearance = NSAppearance(named: .darkAqua)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { matches(centerColor(of: window), .amber, dark: true) }, "amber first")

        UserDefaults.standard.set(ConduitAccentChoice.green.rawValue, forKey: ConduitAccentChoice.storageKey)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { matches(centerColor(of: window), .green, dark: true) },
                      "the swatch kept the old pick: \(String(describing: centerColor(of: window)))")
    }

    /// The redraw round-trips the window appearance inside one run loop turn: afterwards the window has the
    /// appearance it had, and SwiftUI never saw the other colour scheme.
    func testTheRedrawKeepsTheWindowAppearanceAndColorScheme() throws {
        final class Seen { var schemes: [ColorScheme] = [] }
        struct Reader: View {
            @Environment(\.colorScheme) private var scheme
            let seen: Seen
            var body: some View {
                seen.schemes.append(scheme)
                return Color.clear.frame(width: 4, height: 4)
            }
        }
        let seen = Seen()
        let window = HostedTestSupport.host(Reader(seen: seen).macAccentEnvironment(), size: NSSize(width: 4, height: 4))
        let aqua = NSAppearance(named: .aqua)
        window.appearance = aqua
        defer { HostedTestSupport.tearDown(window) }
        HostedTestSupport.settle(0.2)
        XCTAssertEqual(seen.schemes.last, .light, "the window starts light")
        seen.schemes.removeAll()

        MacAccentRedraw.refresh([window])
        HostedTestSupport.settle(0.2)
        XCTAssertTrue(window.appearance === aqua, "the window's own appearance is back")
        XCTAssertFalse(seen.schemes.contains(.dark), "schemes seen during the redraw: \(seen.schemes)")
    }

    func testTheEnvironmentValueFollowsThePick() throws {
        UserDefaults.standard.set(ConduitAccentChoice.teal.rawValue, forKey: ConduitAccentChoice.storageKey)
        final class Seen { var choice: ConduitAccentChoice? }
        struct Reader: View {
            @Environment(\.conduitAccent) private var accent
            let seen: Seen
            var body: some View {
                seen.choice = accent
                return Color.clear.frame(width: 4, height: 4)
            }
        }
        let seen = Seen()
        let window = HostedTestSupport.host(Reader(seen: seen).macAccentEnvironment(), size: NSSize(width: 4, height: 4))
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { seen.choice == .teal })

        UserDefaults.standard.set(ConduitAccentChoice.pink.rawValue, forKey: ConduitAccentChoice.storageKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { seen.choice == .pink }, "saw \(String(describing: seen.choice))")
    }

    // MARK: Hardening

    /// Calls made in one run loop turn share one refresh; a later call makes a new one.
    func testScheduledRefreshesInOneTurnShareOneRun() {
        let before = MacAccentRedraw.scheduledRunCount
        for _ in 0..<5 { MacAccentRedraw.scheduleForAllWindows() }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { MacAccentRedraw.scheduledRunCount > before })
        HostedTestSupport.settle(0.1)
        XCTAssertEqual(MacAccentRedraw.scheduledRunCount, before + 1, "five calls, one run")
        MacAccentRedraw.scheduleForAllWindows()
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { MacAccentRedraw.scheduledRunCount == before + 2 })
    }

    /// An open or save panel, or any window without SwiftUI, never takes the vibrant appearance.
    func testAWindowWithoutSwiftUIIsLeftAlone() {
        final class Spy: NSObject {
            var changes = 0
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
                changes += 1
            }
        }
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let spy = Spy()
        plain.addObserver(spy, forKeyPath: "appearance", options: [], context: nil)
        defer { plain.removeObserver(spy, forKeyPath: "appearance") }
        let hosted = HostedTestSupport.host(AccentSwatch(), size: NSSize(width: 40, height: 40))
        defer { HostedTestSupport.tearDown(hosted) }

        XCTAssertFalse(MacAccentRedraw.showsSwiftUI(plain.contentView!))
        XCTAssertTrue(MacAccentRedraw.showsSwiftUI(hosted.contentView!))
        XCTAssertEqual(MacAccentRedraw.refresh([plain, hosted]), 1, "only the SwiftUI window is refreshed")
        XCTAssertEqual(spy.changes, 0, "the plain window's appearance was never set")
    }

    /// A hosting view that sets the window appearance during layout, the way a `preferredColorScheme` change in the
    /// same transaction would.
    private final class AppearanceChangingHostingView<Content: View>: NSHostingView<Content> {
        var appearanceToSetOnLayout: NSAppearance?
        override func layout() {
            super.layout()
            if let appearance = appearanceToSetOnLayout {
                appearanceToSetOnLayout = nil
                window?.appearance = appearance
            }
        }
    }

    func testAnAppearanceSetDuringLayoutIsNotOverwritten() {
        let view = AppearanceChangingHostingView(rootView: AccentSwatch())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        defer { HostedTestSupport.tearDown(window) }
        HostedTestSupport.settle(0.1)

        view.appearanceToSetOnLayout = NSAppearance(named: .darkAqua)
        view.needsLayout = true
        XCTAssertEqual(MacAccentRedraw.refresh([window]), 1)
        XCTAssertEqual(window.appearance?.name, .darkAqua, "the appearance set during the layout stays")
    }

    /// The window shows a sheet: the parent and the sheet both redraw, and the sheet stays open.
    func testAWindowThatShowsASheetRedrawsBothAndKeepsTheSheet() throws {
        struct Presenter: View {
            var body: some View {
                AccentSwatch()
                    .sheet(isPresented: .constant(true)) {
                        AccentSwatch().frame(width: 60, height: 60).macAccentEnvironment()
                    }
                    .macAccentEnvironment()
            }
        }
        UserDefaults.standard.set(ConduitAccentChoice.amber.rawValue, forKey: ConduitAccentChoice.storageKey)
        let window = HostedTestSupport.host(Presenter(), size: NSSize(width: 200, height: 200))
        window.appearance = NSAppearance(named: .aqua)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 3) { window.attachedSheet != nil }, "the sheet opens")
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNil(sheet.appearance)
        func centre(_ w: NSWindow) -> NSColor? { centerColor(of: w) }
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { matches(centre(sheet), .amber) }, "sheet amber first")

        UserDefaults.standard.set(ConduitAccentChoice.blue.rawValue, forKey: ConduitAccentChoice.storageKey)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 1.5) { matches(centre(sheet), .blue) },
                      "the sheet kept the old pick: \(String(describing: centre(sheet)))")
        XCTAssertTrue(window.attachedSheet === sheet, "the sheet is still open")
        XCTAssertEqual(window.appearance?.name, .aqua, "the parent has its appearance back")
        XCTAssertNil(sheet.appearance, "the sheet has its own (none) back")
    }
}
