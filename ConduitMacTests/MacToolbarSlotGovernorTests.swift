import XCTest
@testable import ConduitMac

/// The strip's width decisions against a simulated toolbar (D11): whatever the
/// trailing items are, the width settles after a handful of steps with no item
/// in the overflow menu, and it never alternates.
final class MacToolbarSlotGovernorTests: XCTestCase {
    /// One trailing item: its natural width, and the narrowest it squeezes to.
    private struct Item { var width: CGFloat; var minWidth: CGFloat }

    /// A toolbar model: `room` from the strip's start to the toolbar's right edge;
    /// trailing items anchored right, nearest first; squeezed last-first before
    /// anything moves to the overflow menu; overflow takes the nearest items first
    /// (what the 0.1.1 toolbar did) and adds a 36 pt overflow button.
    private struct Toolbar {
        var room: CGFloat
        var items: [Item]
        var spacing: CGFloat = 8

        struct Look { var inOverflow: Int; var trailing: Int; var conservative: CGFloat; var optimistic: CGFloat }

        func look(stripWidth: CGFloat) -> Look {
            let strip = max(stripWidth, MacSessionTabMetrics.minWidth)
            var shown = items
            var dropped = 0
            func squeezed(_ list: [Item], available: CGFloat) -> [CGFloat]? {
                var widths = list.map(\.width)
                var excess = list.reduce(0) { $0 + $1.width + spacing } + strip - available
                for index in widths.indices.reversed() where excess > 0 {
                    let take = min(excess, widths[index] - list[index].minWidth)
                    widths[index] -= take
                    excess -= take
                }
                return excess <= 0 ? widths : nil
            }
            var widths = squeezed(shown, available: room)
            while widths == nil, !shown.isEmpty {
                shown.removeFirst()
                dropped += 1
                widths = squeezed(shown, available: room - 36 - spacing)
            }
            let laid = widths ?? []
            let used = laid.reduce(0) { $0 + $1 + spacing } + (dropped > 0 ? 36 + spacing : 0)
            let nearestX = room - used
            let trailingCount = laid.count + (dropped > 0 ? 1 : 0)
            let slack = laid.reduce(CGFloat(0)) { $0 + ($1 - 36 > 4 ? $1 - 36 : 0) }
            let hasTrailing = trailingCount > 0
            return Look(inOverflow: dropped, trailing: trailingCount,
                        conservative: hasTrailing ? max(0, nearestX - MacToolbarSlot.trailingMargin) : 0,
                        optimistic: hasTrailing ? max(0, nearestX + slack - MacToolbarSlot.trailingMargin) : 0)
        }
    }

    private let round = Item(width: 36, minWidth: 36)
    private let search = Item(width: 250, minWidth: 36)
    /// A wide item that does not squeeze: the optimistic guess is wrong for it.
    private let rigid = Item(width: 250, minWidth: 250)

    /// Runs the governor against `toolbar` until it stops setting widths.
    /// Returns the widths it set and the strip's last width.
    private func settle(_ governor: inout MacToolbarSlotGovernor, _ toolbar: Toolbar, from start: CGFloat? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> (sets: [CGFloat], strip: CGFloat) {
        var strip = start ?? governor.last ?? 0
        var sets: [CGFloat] = []
        for _ in 0..<40 {
            let look = toolbar.look(stripWidth: strip)
            switch governor.measured(inOverflow: look.inOverflow, trailing: look.trailing,
                                     conservative: look.conservative, optimistic: look.optimistic) {
            case .set(let width):
                strip = width
                sets.append(width)
            case .recheck: continue
            case .keep: return (sets, strip)
            }
        }
        XCTFail("still changing after 40 steps: \(sets.suffix(8))", file: file, line: line)
        return (sets, strip)
    }

    private func assertSettled(_ toolbar: Toolbar, _ label: String, minimum: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        var governor = MacToolbarSlotGovernor()
        let (sets, strip) = settle(&governor, toolbar)
        let final = toolbar.look(stripWidth: strip)
        XCTAssertEqual(final.inOverflow, 0, "\(label): nothing in the overflow menu; sets \(sets)", file: file, line: line)
        XCTAssertLessThanOrEqual(sets.count, 8, "\(label): settles in a few steps; sets \(sets)", file: file, line: line)
        // Up, then at most one undo and one more climb (the squeeze guess failing,
        // then the conservative width): never a second reversal.
        var directions: [Bool] = []
        for (a, b) in zip(sets, sets.dropFirst()) where abs(b - a) > 0.5 {
            let up = b > a
            if directions.last != up { directions.append(up) }
        }
        XCTAssertLessThanOrEqual(directions.count, 3, "\(label): at most grow, undo, grow; sets \(sets)", file: file, line: line)
        // And measuring again changes nothing.
        XCTAssertTrue(settle(&governor, toolbar).sets.isEmpty, "\(label): a fixed point", file: file, line: line)
    }

    func testSettlesWithNoItemInOverflowForAnyNumberAndKindOfTrailingItems() {
        let kinds: [(String, [Item])] = [
            ("none", []),
            ("one round", [round]),
            ("Refresh, status", [round, round]),
            ("Refresh, status, search", [round, round, search]),
            ("search first", [search, round, round]),
            ("four round", [round, round, round, round]),
            ("rigid wide item", [round, round, rigid]),
            ("only search", [search]),
        ]
        for (name, items) in kinds {
            for room in stride(from: 520 as CGFloat, through: 1700, by: 60) {
                assertSettled(Toolbar(room: room, items: items), "\(name), room \(Int(room))")
            }
        }
    }

    /// Refresh, status and a squeezable search: the strip fills the room the
    /// squeeze frees, and with a rigid wide item it stops at the items' start.
    func testTheStripFillsTheRoomTheItemsCanGiveUp() {
        var governor = MacToolbarSlotGovernor()
        let squeezable = Toolbar(room: 900, items: [round, round, search])
        let (_, strip) = settle(&governor, squeezable)
        XCTAssertEqual(strip, 900 - (36 * 3 + 8 * 3) - MacToolbarSlot.trailingMargin, accuracy: 1, "search squeezed to a magnifier")
        XCTAssertEqual(governor.mode, .optimistic)

        var rigidGovernor = MacToolbarSlotGovernor()
        let rigidBar = Toolbar(room: 900, items: [round, round, rigid])
        let (_, rigidStrip) = settle(&rigidGovernor, rigidBar)
        XCTAssertEqual(rigidStrip, 900 - (36 + 36 + 250 + 8 * 3) - MacToolbarSlot.trailingMargin, accuracy: 1, "up to the items' start")
        XCTAssertEqual(rigidGovernor.mode, .conservative, "the squeeze guess failed once and was undone")
    }

    /// A toolbar whose geometry lies (items vanish whenever the strip is wider
    /// than 300, whatever the platters say) freezes the strip, it does not alternate.
    func testALyingToolbarFreezesTheStripInsteadOfOscillating() {
        var governor = MacToolbarSlotGovernor()
        var strip: CGFloat = 0
        var sets: [CGFloat] = []
        for _ in 0..<40 {
            let overflow = strip > 300 ? 2 : 0
            let step = governor.measured(inOverflow: overflow, trailing: overflow > 0 ? 1 : 3, conservative: 700, optimistic: 700)
            if case .set(let width) = step { strip = width; sets.append(width) } else if step == .keep { break }
        }
        XCTAssertEqual(governor.mode, .frozen)
        XCTAssertEqual(strip, 0, "back to the width it came from")
        XCTAssertLessThanOrEqual(sets.count, 5, "\(sets)")
        XCTAssertEqual(governor.measured(inOverflow: 0, trailing: 3, conservative: 700, optimistic: 700), .keep, "and stays there")
    }

    /// Items that stay out at the smallest strip are not the strip's doing:
    /// after two equal looks the strip grows regardless.
    func testItemsThatStayOutAtTheSmallestStripDoNotHoldTheStripDown() {
        var governor = MacToolbarSlotGovernor()
        XCTAssertEqual(governor.measured(inOverflow: 1, trailing: 2, conservative: 400, optimistic: 400), .recheck)
        XCTAssertEqual(governor.measured(inOverflow: 1, trailing: 2, conservative: 400, optimistic: 400), .set(400))
    }

    /// A window shrink or sidebar change is a new situation: the probation starts over.
    func testARoomChangeStartsTheProbationOver() {
        var governor = MacToolbarSlotGovernor()
        _ = governor.measured(inOverflow: 0, trailing: 3, conservative: 300, optimistic: 400)
        _ = governor.measured(inOverflow: 2, trailing: 1, conservative: 300, optimistic: 400)
        XCTAssertEqual(governor.mode, .conservative)
        governor.roomChanged()
        XCTAssertEqual(governor.mode, .optimistic)
        XCTAssertEqual(governor.shrink(by: 100), .keep, "already back at the width before the failed growth")
    }

    func testTheStripGivesUpRoomAheadOfAShrinkAndWhenLeavingTheWindow() {
        var governor = MacToolbarSlotGovernor()
        XCTAssertEqual(governor.shrink(by: 50), .keep, "nothing to give up yet")
        XCTAssertEqual(governor.measured(inOverflow: 0, trailing: 3, conservative: 500, optimistic: 500), .set(500))
        XCTAssertEqual(governor.shrink(by: 120), .set(380))
        XCTAssertEqual(governor.stripLeftWindow(), .set(0))
        XCTAssertEqual(governor.stripLeftWindow(), .keep, "already at zero")
    }
}
