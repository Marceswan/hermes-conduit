import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// A new accent pick in Settings redraws a hosted Mac scene at once (#697, #702, #750). The Mac dynamic accent colour
/// reads `UserDefaults`, which SwiftUI cannot observe by itself; `macAccentEnvironment()` makes the scene root depend
/// on the pick.
@MainActor
final class MacAccentEnvironmentTests: XCTestCase {
    private var savedPick: Any?

    override func setUp() {
        super.setUp()
        savedPick = UserDefaults.standard.object(forKey: ConduitAccentChoice.storageKey)
    }

    override func tearDown() {
        if let savedPick {
            UserDefaults.standard.set(savedPick, forKey: ConduitAccentChoice.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ConduitAccentChoice.storageKey)
        }
        super.tearDown()
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
        XCTAssertTrue(HostedTestSupport.waitUntil { matches(centerColor(of: window), .blue) },
                      "the swatch kept the old pick: \(String(describing: centerColor(of: window)))")
    }

    func testANewPickRedrawsInDarkAppearance() throws {
        UserDefaults.standard.set(ConduitAccentChoice.amber.rawValue, forKey: ConduitAccentChoice.storageKey)
        let window = HostedTestSupport.host(AccentSwatch().macAccentEnvironment(), size: NSSize(width: 40, height: 40))
        window.appearance = NSAppearance(named: .darkAqua)
        defer { HostedTestSupport.tearDown(window) }
        XCTAssertTrue(HostedTestSupport.waitUntil { matches(centerColor(of: window), .amber, dark: true) }, "amber first")

        UserDefaults.standard.set(ConduitAccentChoice.green.rawValue, forKey: ConduitAccentChoice.storageKey)
        XCTAssertTrue(HostedTestSupport.waitUntil { matches(centerColor(of: window), .green, dark: true) },
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
}
