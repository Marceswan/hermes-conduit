import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Samples the window toolbar of a hosted window and asserts it is whole and
/// still: the check for the D11 flicker class (a toolbar whose items come and
/// go, or whose strip changes width, with the window standing still).
@MainActor
enum ToolbarStability {
    /// What the toolbar shows right now: every platter (window coordinates,
    /// left to right) and which toolbar items sit on the toolbar or in the
    /// overflow menu. Spacers and split-view separators are not items.
    struct Snapshot: Equatable, CustomStringConvertible {
        var windowWidth: CGFloat
        var platters: [ToolbarPlatter]
        var visible: [String]
        var hidden: [String]

        var itemCount: Int { visible.count + hidden.count }

        /// The same toolbar to the eye: the same items, visible and hidden, and
        /// every platter within `tolerance` points of the other's. The system
        /// settles a platter's width over a spring whose tail is a fraction of a
        /// point (834.998, 834, 835 in one run), which nobody sees and which is
        /// not the flicker; an item that moves, resizes or leaves is more.
        func matches(_ other: Snapshot, tolerance: CGFloat = 0.5) -> Bool {
            guard windowWidth == other.windowWidth, visible == other.visible, hidden == other.hidden,
                  platters.count == other.platters.count else { return false }
            return zip(platters, other.platters).allSatisfy { a, b in
                abs(a.frame.minX - b.frame.minX) <= tolerance && abs(a.frame.width - b.frame.width) <= tolerance
                    && abs(a.frame.minY - b.frame.minY) <= tolerance && abs(a.frame.height - b.frame.height) <= tolerance
            }
        }
        var description: String {
            "window \(Int(windowWidth)), platters \(platters.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }), visible \(visible.count), in overflow \(hidden.count)"
        }
    }

    /// Decides when the toolbar has gone quiet and laid out: the same snapshot
    /// (to the eye, see `matches`) in every sample for `quietFor` seconds, with the toolbar in the state the
    /// step expects (`ready`) throughout.
    ///
    /// Stillness alone is not enough. Under load (other test hosts and builds
    /// on the machine) the toolbar's layout after a window or sidebar change
    /// arrives late, by more than any fixed quiet period (the main thread, or
    /// the window server behind it, stalls: one settle wait ran 5.9 s with no
    /// sample changing). The strip platter then sat at its 36 pt starting
    /// size for the whole period, read as quiet, and moved only after it was
    /// asserted. So the quiet period counts only while the toolbar is where the
    /// step says it will end up.
    struct QuietDetector {
        static let quietFor: TimeInterval = 0.5

        private var last: Snapshot
        private var quietSince: Date

        init(_ snapshot: Snapshot, at time: Date) {
            last = snapshot
            quietSince = time
        }

        /// Feeds the sample taken at `time`; true once the toolbar has been
        /// observed unchanged and `ready` for `quietFor`.
        mutating func observe(_ snapshot: Snapshot, ready: Bool = true, at time: Date) -> Bool {
            if !snapshot.matches(last) || !ready {
                last = snapshot
                quietSince = time
            }
            return time.timeIntervalSince(quietSince) >= Self.quietFor
        }
    }

    /// Whether the strip is where `expectSteady` will assert it to be: clear of
    /// the next item, at least `minWidth` (and `minRatio` of the gap) wide and,
    /// when given, `idealWidth`. True when the snapshot has no strip to judge.
    static func stripIsSettled(_ snap: Snapshot, minRatio: CGFloat, idealWidth: CGFloat?) -> Bool {
        guard snap.platters.count >= 3 else { return true }
        let platters = snap.platters
        let gap = platters[2].frame.minX - platters[0].frame.maxX
        guard platters[1].frame.maxX < platters[2].frame.minX,
              platters[1].frame.width >= max(MacSessionTabMetrics.minWidth, gap * minRatio) - 1 else { return false }
        return idealWidth.map { abs(platters[1].frame.width - $0) <= 2 } ?? true
    }

    static func snapshot(of window: NSWindow) -> Snapshot {
        let platters = ToolbarPlatterGeometry.platters(in: window, near: window.frame)
            .map { ToolbarPlatter(frame: $0.frame.offsetBy(dx: -window.frame.minX, dy: 0), cornerRadius: $0.cornerRadius) }
            .sorted { $0.frame.minX < $1.frame.minX }
        // NSToolbarFlexibleSpaceItem and friends, and SwiftUI's tracking separator
        // for the split view's divider: neither is a button on a platter.
        func isSpacer(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier.rawValue.hasPrefix("NSToolbar") || item.itemIdentifier.rawValue.contains("splitViewSeparator")
        }
        let all = (window.toolbar?.items ?? []).filter { !isSpacer($0) }
        let shown = Set((window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        return Snapshot(windowWidth: window.frame.width, platters: platters,
                        visible: all.filter { shown.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue),
                        hidden: all.filter { !shown.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue))
    }

    /// Waits for the toolbar to go quiet and laid out (no change for 0.5 s with
    /// the strip where the checks below expect it, see `QuietDetector`; a first
    /// layout takes a few turns, the flicker never goes quiet), then asserts every
    /// toolbar item is on a platter, none in the overflow menu (unless
    /// `allowOverflow`), the strip is clear of the item after it, fills at
    /// least `minRatio` of the gap between the toggle and that item and, when
    /// `idealWidth` is given, is that wide; and then that the platters and the
    /// visible set stay put for `watch` seconds.
    @discardableResult
    static func expectSteady(in window: NSWindow, _ step: String, minRatio: CGFloat = 0, idealWidth: CGFloat? = nil,
                             allowOverflow: Bool = false, watch: TimeInterval = 1.0,
                             file: StaticString = #filePath, line: UInt = #line) -> Snapshot {
        var latest = snapshot(of: window)
        var detector = QuietDetector(latest, at: Date())
        let quiet = HostedTestSupport.waitUntil(timeout: 10) {
            let now = snapshot(of: window)
            let ready = allowOverflow || stripIsSettled(now, minRatio: minRatio, idealWidth: idealWidth)
            let done = detector.observe(now, ready: ready, at: Date())
            latest = now
            return done
        }
        XCTAssertTrue(quiet, "\(step): the toolbar never went quiet; now \(latest)", file: file, line: line)
        if !allowOverflow {
            XCTAssertTrue(latest.hidden.isEmpty, "\(step): no toolbar item in the overflow menu; now \(latest)", file: file, line: line)
            XCTAssertEqual(latest.platters.count, latest.itemCount, "\(step): one platter per toolbar item; now \(latest)", file: file, line: line)
            if latest.platters.count >= 3 {
                let platters = latest.platters
                XCTAssertLessThan(platters[1].frame.maxX, platters[2].frame.minX, "\(step): the strip clear of the next item; now \(latest)", file: file, line: line)
                let gap = platters[2].frame.minX - platters[0].frame.maxX
                XCTAssertGreaterThanOrEqual(platters[1].frame.width, max(MacSessionTabMetrics.minWidth, gap * minRatio) - 1,
                                            "\(step): the strip fills at least \(minRatio) of the toggle-to-next-item gap; now \(latest)", file: file, line: line)
                if let idealWidth {
                    XCTAssertEqual(platters[1].frame.width, idealWidth, accuracy: 2, "\(step): the strip is its ideal width; now \(latest)", file: file, line: line)
                }
            }
        }
        var seen = [snapshot(of: window)]
        let end = Date().addingTimeInterval(watch)
        while Date() < end {
            HostedTestSupport.settle(0.025)
            let now = snapshot(of: window)
            if let last = seen.last, !now.matches(last) { seen.append(now) }
        }
        XCTAssertEqual(seen.count, 1, "\(step): the toolbar changed while it should be still: \(seen.map(\.description))", file: file, line: line)
        return latest
    }
}
