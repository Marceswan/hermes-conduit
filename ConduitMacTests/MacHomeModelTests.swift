import Combine
import XCTest
@testable import ConduitMac

@MainActor
final class MacHomeModelTests: XCTestCase {
    private final class World {
        var input = MacHomeInput.fixture()
        var refreshes: [MacHomeRefreshReason] = []
        let changes = PassthroughSubject<Void, Never>()
        var clock = MacHomeInput.referenceNow
    }

    private func model(_ world: World, tick: Duration = .seconds(3600), refreshEvery: Int = 2) -> MacHomeModel {
        let sources = MacHomeModel.Sources(
            input: { now in
                var input = world.input
                input.now = now
                return input
            },
            changes: world.changes.eraseToAnyPublisher(),
            refresh: { reason in world.refreshes.append(reason) }
        )
        return MacHomeModel(
            sources: sources, calendar: MacHomeTestCalendar.utc, clock: { world.clock },
            throttle: 0.02, tick: tick, refreshEvery: refreshEvery
        )
    }

    func testInitialSnapshotComesFromTheInput() {
        let world = World()
        world.input = .fixture(sessions: [.fixture("a", at: MacHomeInput.referenceNow)])
        XCTAssertEqual(model(world).snapshot.tiles.sessions, 1)
    }

    func testAChangeRebuildsTheSnapshot() async {
        let world = World()
        let model = model(world)
        world.input = .fixture(sessions: [.fixture("a"), .fixture("b")])
        world.changes.send()
        let rebuilt = await macHomeEventually { model.snapshot.tiles.sessions == 2 }
        XCTAssertTrue(rebuilt)
    }

    func testAnUnchangedInputDoesNotRepublish() async {
        let world = World()
        let model = model(world)
        var publishes = 0
        let sink = model.$snapshot.dropFirst().sink { _ in publishes += 1 }
        defer { sink.cancel() }
        for _ in 0..<5 { world.changes.send() }
        await macHomeSettle(0.3)
        XCTAssertEqual(publishes, 0, "AppState publishes constantly; equal snapshots must not redraw the view")
    }

    func testRunRefreshesOnAppearThenPollsAndStopsWhenCancelled() async {
        let world = World()
        let model = model(world, tick: .milliseconds(15), refreshEvery: 2)
        let task = Task { await model.run() }
        let polled = await macHomeEventually { world.refreshes.count >= 3 }
        XCTAssertTrue(polled)
        XCTAssertEqual(world.refreshes.first, .appeared)
        XCTAssertTrue(world.refreshes.dropFirst().allSatisfy { $0 == .periodic })
        task.cancel()
        await task.value
        let stopped = world.refreshes.count
        await macHomeSettle(0.15)
        XCTAssertEqual(world.refreshes.count, stopped, "no refresh after cancellation")
    }

    func testTheTickMovesTodayAcrossMidnightWithoutAnyDataChange() async {
        let world = World()
        world.clock = MacHomeTestCalendar.date("2026-10-16T23:59:30Z")
        world.input = .fixture(sessions: [.fixture("a", at: MacHomeTestCalendar.date("2026-10-16T12:00:00Z"))])
        let model = model(world, tick: .milliseconds(15), refreshEvery: 1000)
        XCTAssertEqual(model.snapshot.tiles.activeToday, 1)
        let task = Task { await model.run() }
        world.clock = MacHomeTestCalendar.date("2026-10-17T00:00:30Z")
        let rolled = await macHomeEventually { model.snapshot.tiles.activeToday == 0 }
        XCTAssertTrue(rolled)
        XCTAssertEqual(model.snapshot.days.last?.count, 0)
        task.cancel()
        await task.value
    }
}
