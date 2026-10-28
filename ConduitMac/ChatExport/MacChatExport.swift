import Foundation

/// The words the export and the print use (D32). `live` reads the app catalog. Tests pass fixed English,
/// so a fixture never depends on the language of the machine.
struct MacChatExportStrings {
    var you: String
    /// The title of a chat that has none.
    var fallbackTitle: String
    var exported: (_ date: String) -> String
    var olderNotIncluded: String
    var toolLine: (_ name: String, _ status: String) -> String
    var toolRunning: String
    var toolComplete: String
    var attachment: (_ fileName: String) -> String

    static var live: MacChatExportStrings {
        MacChatExportStrings(
            you: AppLocalization.string("You"),
            fallbackTitle: AppLocalization.string("Conversation"),
            exported: { date in AppLocalization.string("Exported \(date)") },
            olderNotIncluded: AppLocalization.string("Mac.ChatExport.OlderNotIncluded"),
            toolLine: { name, status in AppLocalization.string("Tool: \(name) (\(status))") },
            toolRunning: AppLocalization.string("Mac.ChatExport.ToolRunning"),
            toolComplete: AppLocalization.string("Mac.ChatExport.ToolComplete"),
            attachment: { name in AppLocalization.string("Attachment: \(name)") })
    }
}

/// What the command saw when it ran: a copy of the open chat. Every string in it can come from the
/// agent, the user or the host, so the builder treats all of it as data.
struct MacChatExportInput {
    /// The chat's title. Nil or blank reads as `MacChatExportStrings.fallbackTitle`.
    var title: String?
    /// The bot's name, or the profile's. Blank reads as "Hermes".
    var agentName: String
    var messages: [ChatMessage]
    /// True when the chat has older messages that are not loaded.
    var olderMessagesOmitted: Bool
}

/// The chat as the export and the print both read it: values, in order. Pure, no AppKit.
struct MacChatExportDocument: Equatable {
    enum Role: Equatable { case user, agent }

    struct Message: Equatable {
        var role: Role
        /// The role heading: "You", the bot's name, or "Hermes". One line, not yet escaped.
        var speaker: String
        /// "2026-10-28 14:05", or nil when the row has no readable time.
        var time: String?
        /// The message as Markdown.
        var text: String
        /// File names, one line each.
        var attachments: [String]
        /// The tool steps of an agent turn that ran before its text. They print under the heading, before the
        /// text, so a turn's tools never sit under the user's heading.
        var toolSteps: [ToolStep] = []
    }

    struct ToolStep: Equatable {
        var name: String
        var running: Bool
    }

    enum Item: Equatable {
        case message(Message)
        case tool(ToolStep)
    }

    var title: String
    /// "2026-10-28 14:05".
    var exported: String
    var olderOmitted: Bool
    var items: [Item]
}

/// Builds the export of one chat (D32): messages in, Markdown out.
///
/// What goes in: a title line, the export date, then each user and agent row with a role heading, its time
/// when known and its text; each tool step as one line (name and status); each attachment as one line (file
/// name only, never its data). What stays out: thinking text (the `.reasoning` rows and the `reasoning`
/// field), tool input and output, system rows, and the approval, question and password cards.
///
/// Tool steps that come after a user row (or open the chat) belong to the agent turn that follows: they go
/// into that agent row's `toolSteps`. When no agent row with text follows, they get an agent heading of
/// their own, with the time of the first step.
enum MacChatExport {
    static let maxTitleGraphemes = 120
    static let maxNameGraphemes = 80
    static let fallbackAgentName = "Hermes"

    static func markdown(
        _ input: MacChatExportInput, exportedAt: Date, strings: MacChatExportStrings, timeZone: TimeZone = .current
    ) -> String {
        MacChatExportMarkdown.render(
            document(input, exportedAt: exportedAt, strings: strings, timeZone: timeZone), strings: strings)
    }

    static func document(
        _ input: MacChatExportInput, exportedAt: Date, strings: MacChatExportStrings, timeZone: TimeZone = .current
    ) -> MacChatExportDocument {
        let formatter = timeFormatter(timeZone)
        let title = oneLine(input.title ?? "", max: maxTitleGraphemes)
        let agent = oneLine(input.agentName, max: maxNameGraphemes)
        let speaker = agent.isEmpty ? fallbackAgentName : agent
        let time: (ChatMessage) -> String? = { MessageTimestampFormatter.date(from: $0.timestamp).map(formatter.string(from:)) }
        var items: [MacChatExportDocument.Item] = []
        // Tool steps that wait for the agent row of their turn, and the time of the first one.
        var pending: [MacChatExportDocument.ToolStep] = []
        var pendingTime: String?
        // True while the last heading written is the user's (or no heading is written yet).
        var underUser = true
        func flushPending() {
            guard !pending.isEmpty else { return }
            items.append(.message(MacChatExportDocument.Message(
                role: .agent, speaker: speaker, time: pendingTime, text: "", attachments: [], toolSteps: pending)))
            pending = []
            pendingTime = nil
            underUser = false
        }
        for message in input.messages {
            switch message.role {
            case .user, .assistant, .partial:
                let role: MacChatExportDocument.Role = message.role == .user ? .user : .agent
                let text = body(of: message)
                let files = (message.attachments ?? []).map { oneLine($0.name, max: 200) }.filter { !$0.isEmpty }
                guard !text.isEmpty || !files.isEmpty else { continue }
                if role == .user { flushPending() }
                items.append(.message(MacChatExportDocument.Message(
                    role: role,
                    speaker: role == .user ? strings.you : speaker,
                    time: time(message),
                    text: text,
                    attachments: files,
                    toolSteps: role == .user ? [] : pending)))
                if role == .agent {
                    pending = []
                    pendingTime = nil
                }
                underUser = role == .user
            case .tool:
                guard let tool = message.tool else { continue }
                let name = oneLine(tool.name, max: maxNameGraphemes)
                guard !name.isEmpty else { continue }
                let step = MacChatExportDocument.ToolStep(name: name, running: tool.status == .running)
                if underUser {
                    if pending.isEmpty { pendingTime = time(message) }
                    pending.append(step)
                } else {
                    items.append(.tool(step))
                }
            case .reasoning, .system, .clarify, .approval, .inputPrompt:
                continue
            }
        }
        flushPending()
        return MacChatExportDocument(
            title: title.isEmpty ? oneLine(strings.fallbackTitle, max: maxTitleGraphemes) : title,
            exported: formatter.string(from: exportedAt),
            olderOmitted: input.olderMessagesOmitted,
            items: items)
    }

    // MARK: Text

    /// One line: no control or format characters, runs of white space (line breaks too) as one space, cut at `max`.
    static func oneLine(_ text: String, max: Int) -> String {
        MacUntrustedText.sanitize(text, maxGraphemes: max)
    }

    private static func timeFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    /// The row's text as Markdown: a reply envelope as a quote, then the words; for an agent row the code field
    /// as a fenced block.
    private static func body(of message: ChatMessage) -> String {
        var text: String
        if message.role == .user, let envelope = ReplyQuoteEnvelope.parse(message.content) {
            let quote = cleaned(envelope.quote)
            let words = cleaned(envelope.message)
            text = [quote.isEmpty ? nil : MacChatExportMarkdown.blockquote(quote), words.isEmpty ? nil : words]
                .compactMap { $0 }.joined(separator: "\n\n")
        } else {
            text = cleaned(message.content)
        }
        if message.role != .user, let code = message.code {
            // Code is not Markdown: its own fence-like lines are text, so no fence is closed for it.
            let fenced = MacChatExportMarkdown.fenced(cleaned(code, closingFences: false))
            if let fenced { text = text.isEmpty ? fenced : text + "\n\n" + fenced }
        }
        return text
    }

    /// Text from the agent or the user, made safe to sit in the file: line breaks as "\n", control characters
    /// (except tab) dropped, a picture with its data in the text taken out (only the alt text stays), blank
    /// lines at both ends trimmed, and (for Markdown, not for a code field) an open code fence closed so the
    /// rows after it stay rows.
    static func cleaned(_ source: String, closingFences: Bool = true) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control
        }))
        text = strippingDataImages(text)
        let lines = text.components(separatedBy: "\n")
        let isFilled: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.firstIndex(where: isFilled), let last = lines.lastIndex(where: isFilled) else { return "" }
        text = lines[first...last].joined(separator: "\n")
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        if closingFences, let fence = MacChatExportMarkdown.openFence(in: text) {
            text += "\n" + String(repeating: fence.character, count: fence.length)
        }
        return text
    }

    /// A Markdown image or an `<img>` tag whose source is a `data:` URL, reduced to the alt text (nothing for a
    /// tag). Linear in the text, whatever it holds: each search moves forward, and a search that finds no end
    /// ends the pass, because no later start can find one either.
    static func strippingDataImages(_ source: String) -> String {
        guard source.range(of: "data:", options: .caseInsensitive) != nil else { return source }
        return strippingDataImageTags(strippingMarkdownDataImages(source))
    }

    private static func strippingMarkdownDataImages(_ source: String) -> String {
        let text = source as NSString
        let end = text.length
        var out = ""
        var index = 0
        while index < end {
            let start = text.range(of: "![", range: NSRange(location: index, length: end - index))
            guard start.location != NSNotFound else { break }
            let altStart = start.location + 2
            let close = text.range(of: "](", range: NSRange(location: altStart, length: min(500, end - altStart)))
            if close.location != NSNotFound, let target = dataTarget(in: text, after: close.location + 2) {
                let paren = text.range(of: ")", range: NSRange(location: target, length: end - target))
                guard paren.location != NSNotFound else { break }
                out += text.substring(with: NSRange(location: index, length: start.location - index))
                out += text.substring(with: NSRange(location: altStart, length: close.location - altStart))
                index = paren.location + 1
            } else {
                out += text.substring(with: NSRange(location: index, length: altStart - index))
                index = altStart
            }
        }
        return out + text.substring(from: min(index, end))
    }

    /// Where "data:" starts when it follows `location` after spaces, line breaks and one "<". Nil otherwise.
    private static func dataTarget(in text: NSString, after location: Int) -> Int? {
        var at = location
        while at < text.length, text.character(at: at) == 0x20 || text.character(at: at) == 0x0A { at += 1 }
        if at < text.length, text.character(at: at) == 0x3C { at += 1 }
        guard text.length - at >= 5, text.substring(with: NSRange(location: at, length: 5)).lowercased() == "data:" else { return nil }
        return at
    }

    private static func strippingDataImageTags(_ source: String) -> String {
        let text = source as NSString
        let end = text.length
        var out = ""
        var index = 0
        while index < end {
            let start = text.range(of: "<img", options: .caseInsensitive, range: NSRange(location: index, length: end - index))
            guard start.location != NSNotFound else { break }
            let close = text.range(of: ">", range: NSRange(location: start.location, length: end - start.location))
            guard close.location != NSNotFound else { break }
            let tag = text.substring(with: NSRange(location: start.location, length: close.location + 1 - start.location))
            out += text.substring(with: NSRange(location: index, length: start.location - index))
            if tag.range(of: #"\bsrc\s*=\s*["']?\s*data:"#, options: [.regularExpression, .caseInsensitive]) == nil { out += tag }
            index = close.location + 1
        }
        return out + text.substring(from: min(index, end))
    }
}

/// The Markdown writer of the export (D32). Everything it adds around a message (headings, code spans, quote
/// marks, fences) is built so that the message text and the names cannot end it early.
enum MacChatExportMarkdown {
    static func render(_ document: MacChatExportDocument, strings: MacChatExportStrings) -> String {
        var blocks = ["# " + escaped(document.title), strings.exported(document.exported)]
        if document.olderOmitted { blocks.append(strings.olderNotIncluded) }
        // Tool steps and attachments are one paragraph, a line each, joined by a backslash hard break. A list
        // would continue the list a message may end with.
        var steps: [String] = []
        func flushSteps() {
            if !steps.isEmpty { blocks.append(steps.joined(separator: "\\\n")) }
            steps = []
        }
        for item in document.items {
            switch item {
            case .tool(let step):
                steps.append(strings.toolLine(codeSpan(step.name), step.running ? strings.toolRunning : strings.toolComplete))
            case .message(let message):
                flushSteps()
                let heading = escaped(message.speaker) + (message.time.map { " (\($0))" } ?? "")
                blocks.append("## " + heading)
                for step in message.toolSteps {
                    steps.append(strings.toolLine(codeSpan(step.name), step.running ? strings.toolRunning : strings.toolComplete))
                }
                flushSteps()
                if !message.text.isEmpty { blocks.append(message.text) }
                if !message.attachments.isEmpty {
                    blocks.append(message.attachments.map { strings.attachment(codeSpan($0)) }.joined(separator: "\\\n"))
                }
            }
        }
        flushSteps()
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Backslash-escapes what could start Markdown in a line of plain text: a name or a title.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_[]<>~|#".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// An inline code span with a delimiter longer than any backtick run inside it.
    static func codeSpan(_ text: String) -> String {
        let ticks = String(repeating: "`", count: longestRun(of: "`", in: text) + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return ticks + pad + text + pad + ticks
    }

    /// A fenced block with a fence longer than any backtick run in the code. Nil for empty code.
    static func fenced(_ code: String) -> String? {
        guard !code.isEmpty else { return nil }
        let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
        return fence + "\n" + code + "\n" + fence
    }

    static func blockquote(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// The fence still open at the end of `text`, by the CommonMark rules (up to 3 spaces of indent, at least 3
    /// backticks or tildes, a closing fence of the same kind and at least the same length with nothing after it).
    static func openFence(in text: String) -> (character: Character, length: Int)? {
        var open: (character: Character, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent <= 3 else { continue }
            let rest = line.dropFirst(indent)
            guard let first = rest.first, first == "`" || first == "~" else { continue }
            let run = rest.prefix(while: { $0 == first }).count
            guard run >= 3 else { continue }
            let after = rest.dropFirst(run)
            if let current = open {
                if first == current.character, run >= current.length, after.allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
            } else {
                // A backtick fence cannot have a backtick in its info string.
                if first == "`", after.contains("`") { continue }
                open = (first, run)
            }
        }
        return open
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0, current = 0
        for each in text {
            current = each == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
