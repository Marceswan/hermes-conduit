import Combine
import Foundation

typealias NotchAvailability = AgentActivityAvailability
typealias NotchRespondResult = AgentActivityRespondResult

@MainActor
protocol NotchActivitySource: AnyObject {
    var items: [AgentActivityItem] { get }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { get }
    var availability: NotchAvailability { get }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { get }
    /// True once the feed's first poll and its approval fetches finished: what was pending is then the silent baseline.
    var isBaselined: Bool { get }
    var isBaselinedPublisher: AnyPublisher<Bool, Never> { get }
    func respond(to id: String, choice: String) async -> NotchRespondResult
    func dismiss(_ id: String)
    /// Tells the feed a panel is on screen (it polls every 4 s then, 15 s idle).
    func setPanelVisible(_ visible: Bool)
    func refreshNow()
}

@MainActor
final class FeedNotchSource: NotchActivitySource {
    private let feed: AgentActivityFeed
    init(feed: AgentActivityFeed) { self.feed = feed }

    var items: [AgentActivityItem] { feed.items }
    var itemsPublisher: AnyPublisher<[AgentActivityItem], Never> { feed.$items.eraseToAnyPublisher() }
    var availability: NotchAvailability { feed.availability }
    var availabilityPublisher: AnyPublisher<NotchAvailability, Never> { feed.$availability.eraseToAnyPublisher() }
    var isBaselined: Bool { feed.isBaselined }
    var isBaselinedPublisher: AnyPublisher<Bool, Never> { feed.$isBaselined.eraseToAnyPublisher() }
    func respond(to id: String, choice: String) async -> NotchRespondResult { await feed.respond(to: id, choice: choice) }
    func dismiss(_ id: String) { feed.dismiss(id) }
    func setPanelVisible(_ visible: Bool) { feed.setPanelVisible(visible) }
    func refreshNow() { feed.refreshNow() }
}
