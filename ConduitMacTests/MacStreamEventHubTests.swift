import XCTest
@testable import ConduitMac

@MainActor
final class MacStreamEventHubTests: XCTestCase {
    private func label(_ event: StreamEvent) -> String {
        switch event {
        case .messageStart(let id): return "start:\(id)"
        case .messageDelta(let id, let text): return "delta:\(id):\(text)"
        default: return "other"
        }
    }

    func testPublishWithNoSubscribersIsANoOp() {
        MacStreamEventHub().publish(.messageStart(sessionId: "s"))
    }

    func testEverySubscriberReceivesEveryEventInSubscriptionOrder() {
        let hub = MacStreamEventHub()
        var seen: [String] = []
        _ = hub.subscribe { seen.append("a/" + self.label($0)) }
        _ = hub.subscribe { seen.append("b/" + self.label($0)) }
        hub.publish(.messageStart(sessionId: "s1"))
        hub.publish(.messageDelta(sessionId: "s2", text: "x"))
        XCTAssertEqual(seen, ["a/start:s1", "b/start:s1", "a/delta:s2:x", "b/delta:s2:x"])
    }

    func testUnsubscribeStopsDelivery() {
        let hub = MacStreamEventHub()
        var count = 0
        let token = hub.subscribe { _ in count += 1 }
        hub.publish(.messageStart(sessionId: "s"))
        hub.unsubscribe(token)
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testSubscriberAddedDuringPublishMissesThatEvent() {
        let hub = MacStreamEventHub()
        var late = 0
        var added = false
        _ = hub.subscribe { _ in
            guard !added else { return }
            added = true
            _ = hub.subscribe { _ in late += 1 }
        }
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(late, 0)
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(late, 1)
    }

    func testSubscriberRemovedDuringPublishIsSkipped() {
        let hub = MacStreamEventHub()
        var second = 0
        var secondToken: MacStreamEventHub.Token!
        _ = hub.subscribe { _ in hub.unsubscribe(secondToken) }
        secondToken = hub.subscribe { _ in second += 1 }
        hub.publish(.messageStart(sessionId: "s"))
        XCTAssertEqual(second, 0)
    }
}
