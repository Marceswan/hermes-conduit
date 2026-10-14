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
        var description: String {
            "window \(Int(windowWidth)), platters \(platters.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }), visible \(visible.count), in overflow \(hidden.count)"
        }
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

    /// Waits for the toolbar to go quiet (no change for 0.5 s; a first layout
    /// takes a few turns, the flicker never goes quiet), then asserts every
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
        var changedAt = Date()
        let quiet = HostedTestSupport.waitUntil(timeout: 4) {
            let now = snapshot(of: window)
            if now != latest { latest = now; changedAt = Date() }
            return Date().timeIntervalSince(changedAt) >= 0.5
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
            if now != seen.last { seen.append(now) }
        }
        XCTAssertEqual(seen.count, 1, "\(step): the toolbar changed while it should be still: \(seen.map(\.description))", file: file, line: line)
        return latest
    }
}
