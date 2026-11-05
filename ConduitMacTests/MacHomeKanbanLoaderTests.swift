import XCTest
@testable import ConduitMac

@MainActor
final class MacHomeKanbanLoaderTests: XCTestCase {
    private struct Boom: Error {}

    private let todo = [MacHomeKanbanColumnInput(status: "todo", displayName: "To Do", sortOrder: 1, count: 3)]
    private let done = [MacHomeKanbanColumnInput(status: "done", displayName: "Done", sortOrder: 7, count: 5)]

    /// A fetch the test resumes by hand.
    private final class Gate {
        var continuation: CheckedContinuation<[MacHomeKanbanColumnInput], Error>?
        var calls: [String?] = []

        /// Yields to the main actor (so the loader's task can run) until the fetch parks; bounded.
        @MainActor func waitForFetch(timeout: TimeInterval = 30) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while continuation == nil {
                if Date() >= deadline { return false }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return true
        }
    }

    func testLoadsColumnsForTheSavedBoard() async {
        var slugs: [String?] = []
        let loader = MacHomeKanbanLoader { slug in slugs.append(slug); return self.todo }
        XCTAssertEqual(loader.state, .notLoaded)
        await loader.load(preferredSlug: "work")
        XCTAssertEqual(loader.state, .loaded(todo))
        XCTAssertEqual(slugs, ["work"])
    }

    func testEmptySlugAsksForTheServersCurrentBoard() async {
        var slugs: [String?] = []
        let loader = MacHomeKanbanLoader { slug in slugs.append(slug); return self.todo }
        await loader.load(preferredSlug: "")
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(slugs, [nil, nil])
    }

    func testStaleSavedBoardFallsBackToTheCurrentBoardOnce() async {
        var slugs: [String?] = []
        let loader = MacHomeKanbanLoader { slug in
            slugs.append(slug)
            if slug == "gone" { throw Boom() }
            return self.done
        }
        await loader.load(preferredSlug: "gone")
        XCTAssertEqual(slugs, ["gone", nil])
        XCTAssertEqual(loader.state, .loaded(done))
    }

    func testFailureWithNothingLoadedIsUnavailable() async {
        let loader = MacHomeKanbanLoader { _ in throw Boom() }
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(loader.state, .unavailable)
    }

    func testFailureAfterASuccessKeepsTheLastBoard() async {
        var fail = false
        let loader = MacHomeKanbanLoader { _ in
            if fail { throw Boom() }
            return self.todo
        }
        await loader.load(preferredSlug: nil)
        fail = true
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(loader.state, .loaded(todo))
    }

    func testResetDropsALateResponse() async {
        let gate = Gate()
        let loader = MacHomeKanbanLoader { slug in
            gate.calls.append(slug)
            return try await withCheckedThrowingContinuation { gate.continuation = $0 }
        }
        let task = Task { await loader.load(preferredSlug: nil) }
        let parked = await gate.waitForFetch()
        XCTAssertTrue(parked)
        guard parked else { return }
        loader.reset()
        gate.continuation?.resume(returning: todo)
        await task.value
        XCTAssertEqual(loader.state, .notLoaded, "a response for the old scope must not appear")
    }

    func testANewerLoadWinsOverAnOlderOne() async {
        let gate = Gate()
        var first = true
        let loader = MacHomeKanbanLoader { _ in
            if first {
                first = false
                return try await withCheckedThrowingContinuation { gate.continuation = $0 }
            }
            return self.done
        }
        let older = Task { await loader.load(preferredSlug: nil) }
        let parked = await gate.waitForFetch()
        XCTAssertTrue(parked)
        guard parked else { return }
        await loader.load(preferredSlug: nil)
        gate.continuation?.resume(returning: todo)
        await older.value
        XCTAssertEqual(loader.state, .loaded(done))
    }

    func testCancellationLeavesTheStateAlone() async {
        let loader = MacHomeKanbanLoader { _ in throw CancellationError() }
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(loader.state, .notLoaded)
    }

    func testMarkUnavailableAndReset() async {
        let loader = MacHomeKanbanLoader { _ in self.todo }
        loader.markUnavailable()
        XCTAssertEqual(loader.state, .unavailable)
        await loader.load(preferredSlug: nil)
        XCTAssertEqual(loader.state, .loaded(todo))
        loader.markUnavailable()
        XCTAssertEqual(loader.state, .unavailable, "an explicit unavailable (no dashboard) replaces old data")
        loader.reset()
        XCTAssertEqual(loader.state, .notLoaded)
    }
}
