import XCTest
@testable import ConduitMac

final class MacPanelDragTrackerTests: XCTestCase {
    private let start = CGRect(x: 100, y: 200, width: 300, height: 60)

    func testNothingMovesBeforeAPointerHasBeenPressed() {
        var tracker = MacPanelDragTracker(threshold: 4)
        XCTAssertNil(tracker.move(to: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(tracker.end())
    }

    func testMovementUnderTheThresholdIsNotADrag() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: CGPoint(x: 10, y: 10), frame: start)
        XCTAssertNil(tracker.move(to: CGPoint(x: 13, y: 10)))
        XCTAssertNil(tracker.move(to: CGPoint(x: 12.5, y: 12.5)))
        XCTAssertFalse(tracker.isDragging)
        XCTAssertFalse(tracker.end(), "a click, not a drag")
    }

    func testMovementAtTheThresholdStartsTheDragAndTheFrameFollowsThePointer() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: CGPoint(x: 10, y: 10), frame: start)
        XCTAssertEqual(tracker.move(to: CGPoint(x: 14, y: 10)), start.offsetBy(dx: 4, dy: 0))
        XCTAssertTrue(tracker.isDragging)
        XCTAssertEqual(tracker.move(to: CGPoint(x: 11, y: 8)), start.offsetBy(dx: 1, dy: -2), "once started, no threshold")
        XCTAssertTrue(tracker.end())
    }

    func testEndResetsSoTheNextPressStartsFresh() {
        var tracker = MacPanelDragTracker(threshold: 4)
        tracker.begin(pointer: .zero, frame: start)
        _ = tracker.move(to: CGPoint(x: 20, y: 0))
        XCTAssertTrue(tracker.end())
        XCTAssertFalse(tracker.isDragging)
        XCTAssertNil(tracker.move(to: CGPoint(x: 50, y: 0)))
        XCTAssertFalse(tracker.end())
    }
}
