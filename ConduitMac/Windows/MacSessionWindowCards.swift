import SwiftUI

// The session window's own minimal cards (D21). They render an activity and report a choice;
// the controller owns the wire call and the submitting/error/expired states, so these hold
// no AppState. Upstream's cards (ChatView.swift) call AppState with ids from AppState's messages.

private struct MacWindowCardSurface<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: tint.opacity(0.08))
    }
}

private struct MacWindowCardHeader: View {
    let icon: String
    let title: String
    let tint: Color
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
        }
    }
}

private struct MacWindowCardError: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}

// MARK: - Approval

struct MacWindowApprovalCard: View {
    let activity: ApprovalActivity
    let onChoose: (String) -> Void
    @State private var confirmAlways = false

    /// Upstream's labels (ApprovalCard.decisionTitle, ChatView.swift).
    static func label(for choice: String) -> String {
        switch choice {
        case "once": return AppLocalization.string("Approved once")
        case "session": return AppLocalization.string("Approved for this session")
        case "always": return AppLocalization.string("Always allowed")
        case "deny": return AppLocalization.string("Rejected")
        default: return MacUntrustedText.sanitize(choice, maxGraphemes: 40)
        }
    }

    /// Upstream's `allows`: the offered choices, with "always" also gated on `allowPermanent`.
    static func allows(_ choice: String, for approval: ApprovalActivity) -> Bool {
        let choices = approval.choices ?? (approval.smartDenied ? ["once", "deny"] : ["once", "session", "always", "deny"])
        if choice == "always" && !approval.allowPermanent { return false }
        return choices.contains(choice)
    }

    private var canRespond: Bool { activity.status == .pending || activity.status == .error }

    /// An approval's error text can be the gateway's withdrawal reason (`approvalWithdrawn`), so it is
    /// sanitized like every other gateway string in the window's chrome. Nil when there is nothing to show.
    static func displayError(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let clean = MacUntrustedText.sanitize(raw, maxGraphemes: 300)
        return clean.isEmpty ? nil : clean
    }

    var body: some View {
        MacWindowCardSurface(tint: statusColor) {
            MacWindowCardHeader(icon: "checkmark.shield", title: statusTitle, tint: statusColor,
                                busy: activity.status == .submitting)
            if !activity.description.isEmpty {
                Text(activity.description)
                    .font(.subheadline.weight(.bold))
                    .textSelection(.enabled)
            }
            if !activity.command.isEmpty {
                Text(activity.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            switch activity.status {
            case .approved, .rejected:
                let text = activity.choice.map(Self.label(for:)) ?? statusTitle
                Label(text, systemImage: activity.status == .approved ? "checkmark" : "xmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor)
            case .expired:
                Text(Self.displayError(activity.error)
                     ?? AppLocalization.string("This approval is no longer active — Hermes timed it out and continued."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .pending, .submitting, .error:
                buttons
            }
            if activity.status != .expired, let error = Self.displayError(activity.error) {
                MacWindowCardError(text: error)
            }
        }
        .confirmationDialog(AppLocalization.string("Always allow this command?"),
                            isPresented: $confirmAlways, titleVisibility: .visible) {
            Button(AppLocalization.string("Always allow"), role: .destructive) { send("always") }
        } message: {
            Text(AppLocalization.string("Hermes will save this approval pattern for future commands."))
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { send("once") } label: { Label(AppLocalization.string("Run"), systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.conduitAccent)
                .disabled(!Self.allows("once", for: activity) || !canRespond)
            if Self.allows("session", for: activity) {
                Button(AppLocalization.string("Allow session")) { send("session") }
                    .buttonStyle(.bordered)
                    .disabled(!canRespond)
            }
            if Self.allows("always", for: activity) {
                Button(AppLocalization.string("Always allow")) { confirmAlways = true }
                    .buttonStyle(.bordered)
                    .disabled(!canRespond)
            }
            Spacer(minLength: 0)
            Button(AppLocalization.string("Reject"), role: .destructive) { send("deny") }
                .buttonStyle(.bordered)
                .disabled(!Self.allows("deny", for: activity) || !canRespond)
        }
        .font(.subheadline.weight(.medium))
    }

    private func send(_ choice: String) {
        guard Self.allows(choice, for: activity), canRespond else { return }
        onChoose(choice)
    }

    private var statusTitle: String {
        switch activity.status {
        case .pending: return AppLocalization.string("APPROVAL NEEDED")
        case .submitting: return AppLocalization.string("SENDING DECISION")
        case .approved: return AppLocalization.string("APPROVED")
        case .rejected: return AppLocalization.string("REJECTED")
        case .expired: return AppLocalization.string("EXPIRED")
        case .error: return AppLocalization.string("TRY AGAIN")
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .pending, .submitting: return .orange
        case .approved: return .green
        case .rejected, .expired, .error: return .red
        }
    }
}

// MARK: - Clarify

struct MacWindowClarifyCard: View {
    let activity: ClarifyActivity
    let onAnswer: (_ questionID: String, _ answer: String) -> Void

    var body: some View {
        MacWindowCardSurface(tint: statusColor) {
            MacWindowCardHeader(icon: "questionmark.bubble", title: statusTitle, tint: statusColor,
                                busy: activity.status == .submitting)
            ForEach(activity.questions) { question in
                MacWindowClarifyQuestionRow(question: question, requestExpired: activity.isExpired) {
                    onAnswer(question.id, $0)
                }
            }
            if activity.isExpired {
                Text(AppLocalization.string("No longer active")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = activity.error, !error.isEmpty { MacWindowCardError(text: error) }
        }
    }

    private var statusTitle: String {
        switch activity.presentationStatus {
        case .pending: return AppLocalization.string("NEEDS YOUR INPUT")
        case .submitting: return AppLocalization.string("SENDING ANSWER")
        case .answered: return AppLocalization.string("ANSWERED")
        case .error: return AppLocalization.string("TRY AGAIN")
        case .expired: return AppLocalization.string("EXPIRED")
        }
    }

    private var statusColor: Color {
        switch activity.presentationStatus {
        case .pending, .submitting: return .orange
        case .answered: return .green
        case .error, .expired: return .red
        }
    }
}

struct MacWindowClarifyQuestionRow: View {
    let question: ClarifyQuestion
    let requestExpired: Bool
    let onAnswer: (String) -> Void
    @State private var text = ""
    @State private var selection: Set<String> = []

    /// Upstream's rule (`ClarifyQuestion.isAnswerable`: pending or error, so a failed answer can be retried),
    /// unless the whole request expired.
    static func isAnswerable(_ question: ClarifyQuestion, requestExpired: Bool) -> Bool {
        question.isAnswerable && !requestExpired
    }

    /// What a free-text answer sends: trimmed, nil when blank.
    static func freeTextAnswer(_ text: String) -> String? {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    private var answerable: Bool { Self.isAnswerable(question, requestExpired: requestExpired) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.subheadline.weight(.bold))
                .textSelection(.enabled)
            if answerable {
                if question.isFreeText { freeText } else { choices }
            } else {
                resolved
            }
            if let error = question.error, !error.isEmpty { MacWindowCardError(text: error) }
        }
    }

    @ViewBuilder
    private var resolved: some View {
        switch question.status {
        case .answered:
            if let answer = question.resolvedAnswer {
                Label(answer, systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
        case .submitting:
            ProgressView().controlSize(.small)
        case .expired:
            Text(AppLocalization.string("EXPIRED")).font(.caption).foregroundStyle(.secondary)
        case .pending, .error:
            // Only reachable when the whole request expired.
            Text(AppLocalization.string("EXPIRED")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var freeText: some View {
        HStack(spacing: 8) {
            TextField(AppLocalization.string("Type your answer…"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitText)
            Button(AppLocalization.string("Send"), action: submitText)
                .buttonStyle(.borderedProminent)
                .tint(.conduitAccent)
                .disabled(Self.freeTextAnswer(text) == nil)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(question.choices) { choice in
                if question.multiSelect {
                    Toggle(choice.label, isOn: Binding(
                        get: { selection.contains(choice.value) },
                        set: { if $0 { selection.insert(choice.value) } else { selection.remove(choice.value) } }))
                } else {
                    Button(choice.label) { onAnswer(choice.value) }
                        .buttonStyle(.bordered)
                }
            }
            if question.multiSelect {
                Button(selection.isEmpty ? AppLocalization.string("Select to confirm")
                                         : AppLocalization.string("Confirm \(selection.count) selected")) {
                    // Gateway choice order, like ClarifyQuestion.resolvedAnswer.
                    onAnswer(ClarifyQuestion.multiSelectAnswer(question.choices.map(\.value).filter(selection.contains)))
                }
                .buttonStyle(.borderedProminent)
                .tint(.conduitAccent)
                .disabled(selection.isEmpty)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    private func submitText() {
        guard let answer = Self.freeTextAnswer(text) else { return }
        onAnswer(answer)
    }
}

// MARK: - Input prompt (sudo, secret, vault unlock)

struct MacWindowInputPromptCard: View {
    let activity: InputPromptActivity
    /// nil = Skip.
    let onSubmit: (String?) -> Void
    /// The typed secret lives in this view's state only; it is handed to the controller once.
    @State private var value = ""

    private var hasValue: Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        MacWindowCardSurface(tint: statusColor) {
            MacWindowCardHeader(icon: icon, title: statusTitle, tint: statusColor, busy: activity.status == .submitting)
            Text(activity.title)
                .font(.subheadline.weight(.bold))
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            switch activity.status {
            case .submitted:
                Label(AppLocalization.string("Sent"), systemImage: "checkmark")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.green)
            case .skipped:
                Label(AppLocalization.string("Skipped"), systemImage: "forward")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            case .expired:
                Text(activity.error.flatMap { $0.isEmpty ? nil : $0 } ?? AppLocalization.string("This request is no longer active."))
                    .font(.caption).foregroundStyle(.secondary)
            case .pending, .submitting, .error:
                entry
            }
            if activity.status == .error, let error = activity.error, !error.isEmpty { MacWindowCardError(text: error) }
        }
        .onChange(of: activity.status) { _, status in
            // Settled either way: drop the value. A failed send (.error) keeps it for a retry.
            if status == .submitted || status == .skipped || status == .expired { value = "" }
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No password content type: it would offer to save a sudo or vault master password.
            SecureField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .accessibilityHint(AppLocalization.string("Send gives Hermes this value. Skip lets it continue without one."))
                .onSubmit(submit)
                .disabled(!activity.isAnswerable)
            HStack(spacing: 8) {
                Button(action: submit) { Label(AppLocalization.string("Send"), systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .disabled(!activity.isAnswerable || !hasValue)
                Spacer(minLength: 0)
                Button(AppLocalization.string("Skip")) { value = ""; onSubmit(nil) }
                    .buttonStyle(.bordered)
                    .disabled(!activity.isAnswerable)
            }
            .font(.subheadline.weight(.medium))
        }
    }

    private func submit() {
        guard activity.isAnswerable, hasValue else { return }
        // Sent untrimmed: a password may contain spaces.
        onSubmit(value)
    }

    private var detail: String? {
        switch activity.kind {
        case .sudo: return activity.command
        case .secret: return activity.envVar
        case .vaultUnlock: return nil
        }
    }

    private var icon: String {
        switch activity.kind {
        case .sudo: return "lock.shield"
        case .secret: return "key"
        case .vaultUnlock: return "lock.rectangle.stack"
        }
    }

    private var placeholder: String {
        switch activity.kind {
        case .sudo: return AppLocalization.string("sudo password")
        case .secret: return AppLocalization.string("Secret value")
        case .vaultUnlock: return AppLocalization.string("Master password")
        }
    }

    private var statusTitle: String {
        switch activity.status {
        case .pending: return AppLocalization.string("INPUT NEEDED")
        case .submitting: return AppLocalization.string("SENDING")
        case .submitted: return AppLocalization.string("SENT")
        case .skipped: return AppLocalization.string("SKIPPED")
        case .expired: return AppLocalization.string("EXPIRED")
        case .error: return AppLocalization.string("TRY AGAIN")
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .pending, .submitting: return .orange
        case .submitted: return .green
        case .skipped: return .secondary
        case .expired, .error: return .red
        }
    }
}
