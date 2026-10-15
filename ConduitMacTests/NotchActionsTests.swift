import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class NotchActionsTests: XCTestCase {
    func testOpenPaneWritesTheSidebarTabKey() {
        let s = HostedTestSupport.makeSuite(); defer { HostedTestSupport.dropSuite(s) }
        NotchActions.selectPane(.kanban, defaults: s.defaults)
        XCTAssertEqual(s.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.kanban.rawValue)
        NotchActions.selectPane(.cron, defaults: s.defaults)
        XCTAssertEqual(s.defaults.string(forKey: MacSidebarState.tabDefaultsKey), SidebarTab.cron.rawValue)
    }

    func testTaskSchedulerFiresOnceAndCancels() async {
        let scheduler = TaskTimerScheduler()
        let fired = expectation(description: "fired")
        fired.assertForOverFulfill = true
        _ = scheduler.schedule(after: 0.01) { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 5)
        var cancelledFired = 0
        let cancel = scheduler.schedule(after: 0.05) { cancelledFired += 1 }
        cancel()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(cancelledFired, 0)
    }
}
