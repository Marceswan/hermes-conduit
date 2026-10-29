import Combine
import Foundation

@MainActor
final class NotchStatusViewModel: ObservableObject {
    enum EmptyState: Equatable { case noAgents, disconnected }

    @Published var surface: NotchSurface = .hidden
    @Published var list: NotchRowList = .empty
    @Published var availability: NotchAvailability = .live
    @Published var buttonsEnabled = true
    @Published var newChatEnabled = true
    @Published var placement: NotchPlacement = .pill
    @Published var contentHeight: CGFloat = 0
    @Published var submitting: Set<String> = []
    @Published var failedRows: Set<String> = []

    @Published var layout: NotchLayout = .make(standardIsNotch: false, dock: nil)
    /// The chosen surface style (Settings), and the two facts that can override it. The controller
    /// keeps `reduceTransparency` in step with the system setting.
    @Published var surfaceStyle: NotchSurfaceStyle = .glass
    @Published var reduceTransparency = false
    var glassAvailable = NotchSurfaceStyle.glassAvailable
    var onResetPosition: () -> Void = {}

    /// The style that is painted: the choice, resolved for this placement, then for this Mac.
    var drawnSurfaceStyle: NotchSurfaceStyle {
        surfaceStyle.drawn(on: layout, glassAvailable: glassAvailable, reduceTransparency: reduceTransparency)
    }

    /// Light or dark comes from the Mac only for system glass; every other outcome is a dark surface.
    var followsSystemAppearance: Bool {
        surfaceStyle.followsSystemAppearance(glassAvailable: glassAvailable, reduceTransparency: reduceTransparency)
    }

    /// The standard placement on a notch display: its band is welded to the hardware, so it stays
    /// black where it touches the notch whatever the chosen style.
    var weldsToHardwareNotch: Bool { layout.style == .wings && placement.notchWidth > 0 }

    /// Height to leave empty at the top of the expanded panel: only the standard
    /// wings layout sits beside a physical notch.
    var reservedTopHeight: CGFloat { layout.style == .wings ? placement.notchHeight : 0 }

    var onOpenRow: (NotchRow) -> Void = { _ in }
    /// A button or menu item was activated. The controller maps the action to a choice and
    /// answers by the row's item id; no text from the row is read back.
    var onAction: (NotchRow, NotchApprovalAction) -> Void = { _, _ in }
    var onDismissRow: (String) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var onOpenConduit: () -> Void = {}
    var onOpenCron: () -> Void = {}
    var onOpenMore: () -> Void = {}

    var emptyState: EmptyState { availability == .offline ? .disconnected : .noAgents }
    var showsEventsOnlyNote: Bool { availability == .eventsOnly }

    func canChoose(rowID: String) -> Bool { buttonsEnabled && !submitting.contains(rowID) }

    var compactLabel: NotchCompactLabel { NotchCompactLabel.make(counts: list.counts, items: list.rows) }

    /// "Agent status: 2 working, 1 need you" (one count per key, joined in code).
    var accessibilitySummary: String {
        var parts: [String] = []
        let c = list.counts
        let workingCount = c.working
        let needsCount = c.needsUser
        if workingCount > 0 { parts.append(AppLocalization.string("\(workingCount) working")) }
        if needsCount > 0 { parts.append(AppLocalization.string("\(needsCount) need you")) }
        let body = parts.isEmpty ? AppLocalization.string("idle") : parts.joined(separator: ", ")
        return AppLocalization.string("Agent status: \(body)")
    }
}
