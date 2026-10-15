import Foundation

struct NotchApprovalChoices: Equatable {
    var once = false
    var deny = false
    var session = false
    var always = false
    var hasInlineButtons: Bool { once || deny }

    /// The choice rule is the shared base's (`AgentActivityApprovalChoices.allowed(for:)`:
    /// explicit choices win, else the default set, smart-denied requests offer only once
    /// and deny, and `always` also needs `allowPermanent`). This only maps it to buttons;
    /// Session and Always are menu-only.
    static func resolve(_ a: ApprovalActivity) -> NotchApprovalChoices {
        let allowed = Set(AgentActivityApprovalChoices.allowed(for: a))
        return NotchApprovalChoices(
            once: allowed.contains(AgentActivityApprovalChoices.once),
            deny: allowed.contains(AgentActivityApprovalChoices.deny),
            session: allowed.contains(AgentActivityApprovalChoices.session),
            always: allowed.contains(AgentActivityApprovalChoices.always))
    }
}

struct NotchCounts: Equatable {
    var decisions = 0   // approval, clarify, input prompt: the interruptive kinds
    var needsUser = 0   // decisions + Kanban blocked or review
    var working = 0
    var recent = 0      // finished rows still shown
    var isActive: Bool { needsUser + working > 0 }
    var hasAnything: Bool { isActive || recent > 0 }
}

struct NotchCronInfo: Equatable {
    var title: String
    var at: Date
}

struct NotchRow: Identifiable, Equatable {
    enum Section: Int, Comparable {
        case needsYou, working, done
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }
    enum Target: Equatable { case session(String), kanban, cron }
    enum Inline: Equatable {
        case none
        case approval(NotchApprovalChoices, NotchApprovalContent)
        case answerInConduit   // clarify, sudo, secret, vault: never inline
        case openToAnswer      // approval content not captured or no usable choice
    }
    enum Tone: Equatable { case normal, attention, failed }

    let id: String
    var section: Section
    var title: String
    var detail: String?
    var target: Target?
    var inline: Inline
    var tone: Tone
    var canDismiss: Bool
    /// The item's durable session id, kept so the action layer can re-check the live item before answering.
    var sessionKey: String? = nil
}

struct NotchRowList: Equatable {
    var rows: [NotchRow]
    var overflow: Int
    var counts: NotchCounts
    var cron: NotchCronInfo?
    var nextExpiry: Date?
    static let empty = NotchRowList(rows: [], overflow: 0, counts: NotchCounts(), cron: nil, nextExpiry: nil)
}

enum NotchRowBuilder {
    static let maxRows = 6
    static let doneLifetime: TimeInterval = 30
    static let maxDone = 3
    static let commandLimit = 160

    static func build(items: [AgentActivityItem], now: Date) -> NotchRowList {
        let decisionSessions = Set(items.compactMap { i -> String? in
            guard isDecision(i.kind), case .needsUser = i.state else { return nil }
            return i.sessionKey ?? i.sessionId
        })

        var needs: [NotchRow] = [], working: [NotchRow] = []
        var done: [(row: NotchRow, since: Date)] = []
        var cron: NotchCronInfo?
        var counts = NotchCounts()

        for i in items {
            switch (i.kind, i.state) {
            case (.cron, _):
                if cron == nil { cron = NotchCronInfo(title: MacUntrustedText.sanitize(i.title, maxGraphemes: titleLimit), at: i.since) }
            case (.turn, .working):
                if let key = i.sessionKey ?? i.sessionId, decisionSessions.contains(key) { continue }
                counts.working += 1
                working.append(row(i, .working, tone: .normal, inline: .none))
            case (.turn, .finished(let outcome)):
                guard now.timeIntervalSince(i.since) <= doneLifetime else { continue }
                var r = row(i, .done, tone: .normal, inline: .none)
                if case .failed(let message) = outcome { r.tone = .failed; r.detail = truncatedCommand(message) }
                r.canDismiss = true
                done.append((r, i.since))
            case (.kanban, .blocked), (.kanban, .needsUser):
                counts.needsUser += 1
                var r = row(i, .needsYou, tone: .attention, inline: .none)
                r.target = .kanban
                needs.append(r)
            case (let kind, .needsUser) where isDecision(kind):
                counts.needsUser += 1; counts.decisions += 1
                needs.append(row(i, .needsYou, tone: .attention, inline: inline(for: i)))
            default:
                continue
            }
        }

        let newestDone = done.sorted { $0.since > $1.since }.prefix(maxDone)
        counts.recent = newestDone.count
        let ordered = needs + working + newestDone.map(\.row)
        return NotchRowList(
            rows: Array(ordered.prefix(maxRows)), overflow: max(0, ordered.count - maxRows),
            counts: counts, cron: cron,
            nextExpiry: newestDone.map { $0.since.addingTimeInterval(doneLifetime) }.min())
    }

    static let titleLimit = 80

    /// Sanitized (control, bidi and zero-width characters dropped, whitespace and newlines
    /// collapsed) and cut at 160 chars. Never log the result: it can contain secrets.
    static func truncatedCommand(_ text: String) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: commandLimit)
    }

    private static func isDecision(_ k: AgentActivityItem.Kind) -> Bool {
        k == .approval || k == .clarify || k == .inputPrompt
    }

    private static func inline(for i: AgentActivityItem) -> NotchRow.Inline {
        guard i.kind == .approval else { return .answerInConduit }
        guard let a = i.approval else { return .openToAnswer }
        let choices = NotchApprovalChoices.resolve(a)
        return choices.hasInlineButtons ? .approval(choices, NotchApprovalContent.make(a)) : .openToAnswer
    }

    private static func row(_ i: AgentActivityItem, _ section: NotchRow.Section, tone: NotchRow.Tone, inline: NotchRow.Inline) -> NotchRow {
        // Everything the agent or gateway supplies is sanitized here, once, so no view renders raw text.
        let clean = MacUntrustedText.sanitize(i.title, maxGraphemes: titleLimit)
        let title = clean.isEmpty ? AppLocalization.string("Untitled chat") : clean
        let id = i.sessionId ?? i.sessionKey
        var detail = i.detail.map(truncatedCommand).flatMap { $0.isEmpty ? nil : $0 }
        // An approval row shows the payload (summary and command), never a second, agent-worded line.
        if case .approval = inline { detail = nil }
        return NotchRow(
            id: i.id, section: section, title: title, detail: detail,
            target: id.map { .session($0) }, inline: inline, tone: tone, canDismiss: false,
            sessionKey: i.sessionKey)
    }
}

enum NotchItemDiff {
    static func transitions(old: [AgentActivityItem], new: [AgentActivityItem]) -> (newDecision: Bool, newFinish: Bool) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var decision = false, finish = false
        for i in new {
            let before = oldByID[i.id]
            switch i.state {
            case .needsUser where i.kind == .approval || i.kind == .clarify || i.kind == .inputPrompt:
                if before == nil { decision = true }
            case .finished where i.kind == .turn:
                if case .finished? = before?.state { break }
                finish = true
            default: break
            }
        }
        return (decision, finish)
    }
}

enum NotchCompactLabel: Equatable {
    case needYou(Int), tool(String), working(Int), done, none

    static func make(counts: NotchCounts, items rows: [NotchRow]) -> NotchCompactLabel {
        if counts.needsUser > 0 { return .needYou(counts.needsUser) }
        if counts.working == 1, let tool = rows.first(where: { $0.section == .working })?.detail, !tool.isEmpty { return .tool(tool) }
        if counts.working > 0 { return .working(counts.working) }
        return counts.recent > 0 ? .done : .none
    }

    /// The one-token form for the vertical capsule (left and right edges), which has no room for words.
    var shortCount: String? {
        switch self {
        case .needYou(let n), .working(let n): return String(n)
        case .tool: return "1"
        case .done: return "\u{2713}"
        case .none: return nil
        }
    }
}
