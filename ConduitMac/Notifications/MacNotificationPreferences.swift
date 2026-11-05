import Foundation

/// Per-Mac notification preferences (`conduit.mac.notifications.*`).
@MainActor
final class MacNotificationPreferences: ObservableObject {
    static let shared = MacNotificationPreferences()

    enum Key {
        static let enabled = "conduit.mac.notifications.enabled"
        static let done = "conduit.mac.notifications.done"
        static let approvals = "conduit.mac.notifications.approvals"
        static let questions = "conduit.mac.notifications.questions"
        static let sound = "conduit.mac.notifications.sound"
        static let threshold = "conduit.mac.notifications.thresholdSeconds"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    @Published var notifiesDone: Bool { didSet { defaults.set(notifiesDone, forKey: Key.done) } }
    @Published var notifiesApprovals: Bool { didSet { defaults.set(notifiesApprovals, forKey: Key.approvals) } }
    @Published var notifiesQuestions: Bool { didSet { defaults.set(notifiesQuestions, forKey: Key.questions) } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    @Published var threshold: TimeInterval {
        didSet {
            if !MacNotificationPolicy.thresholdChoices.contains(threshold) {
                threshold = MacNotificationPolicy.defaultThreshold
                return
            }
            defaults.set(threshold, forKey: Key.threshold)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        isEnabled = flag(Key.enabled)
        notifiesDone = flag(Key.done)
        notifiesApprovals = flag(Key.approvals)
        notifiesQuestions = flag(Key.questions)
        soundEnabled = flag(Key.sound)
        let stored = (defaults.object(forKey: Key.threshold) as? NSNumber)?.doubleValue
        threshold = stored.flatMap { MacNotificationPolicy.thresholdChoices.contains($0) ? $0 : nil }
            ?? MacNotificationPolicy.defaultThreshold
    }

    func allows(_ kind: MacNotificationKind) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case .done, .failed: return notifiesDone
        case .approval: return notifiesApprovals
        case .question: return notifiesQuestions
        case .notice: return true
        }
    }
}
