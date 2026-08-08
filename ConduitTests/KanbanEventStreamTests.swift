import XCTest
@testable import Conduit

final class KanbanEventStreamTests: XCTestCase {

    func testParseFrameExtractsCountAndCursor() {
        let frame = KanbanEventStream.parseFrame(#"{"events":[{"id":4,"kind":"status"},{"id":7,"kind":"claimed"}],"cursor":7}"#)
        XCTAssertEqual(frame, KanbanEventFrame(eventCount: 2, cursor: 7))
    }

    func testParseFrameEmptyEventsYieldsZeroCountWithCursor() {
        let frame = KanbanEventStream.parseFrame(#"{"events":[],"cursor":12}"#)
        XCTAssertEqual(frame, KanbanEventFrame(eventCount: 0, cursor: 12))
    }

    func testParseFrameMissingEventsButCursorPresentCountsZero() {
        let frame = KanbanEventStream.parseFrame(#"{"cursor":33}"#)
        XCTAssertEqual(frame, KanbanEventFrame(eventCount: 0, cursor: 33))
    }

    func testParseFrameMissingCursorFallsBackToMaxEventID() {
        let frame = KanbanEventStream.parseFrame(#"{"events":[{"id":9},{"id":3}]}"#)
        XCTAssertEqual(frame, KanbanEventFrame(eventCount: 2, cursor: 9))
    }

    func testParseFrameGarbageReturnsNilWithoutTrap() {
        XCTAssertNil(KanbanEventStream.parseFrame("not json"))
        XCTAssertNil(KanbanEventStream.parseFrame("[1,2,3]"))
        XCTAssertNil(KanbanEventStream.parseFrame(#"{"foo":1}"#))
        XCTAssertNil(KanbanEventStream.parseFrame(""))
    }

    func testParseFrameCoercesNumericStringCursor() {
        let frame = KanbanEventStream.parseFrame(#"{"events":[],"cursor":"41"}"#)
        XCTAssertEqual(frame?.cursor, 41)
    }
}
