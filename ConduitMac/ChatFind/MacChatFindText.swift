import Foundation

/// The plain text a message draws, for searching rows that are not built.
/// Built with the same parser and inline builder the views use, so link
/// destinations, emphasis marks, fences and table separators are absent.
enum MacChatFindText {
    static func isSearchable(_ role: MessageRole) -> Bool {
        switch role {
        case .user, .assistant, .partial: return true
        case .system, .reasoning, .tool, .clarify, .approval, .inputPrompt: return false
        }
    }

    /// nil: the row is not searched, or draws no text.
    static func searchableText(for message: ChatMessage) -> String? {
        guard isSearchable(message.role) else { return nil }
        var parts: [String] = []
        // The user bubble draws the reply-quote envelope as a card, not as text.
        let source = message.role == .user
            ? (ReplyQuoteEnvelope.parse(message.content)?.message ?? message.content)
            : message.content
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(plain(fromMarkdown: source))
        }
        if message.role != .user, let code = message.code, !code.isEmpty {
            parts.append(code)
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    static func plain(fromMarkdown source: String) -> String {
        let document = MarkdownParser.parseDocument(source)
        let references = document.references
        func inline(_ text: String) -> String {
            String(InlineMarkdownContent.attributed(source: text, references: references).characters)
        }
        var lines: [String] = []
        for block in document.blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text):
                lines.append(inline(text))
            case .callout(_, let text):
                lines.append(inline(text))
            case .quote(let quoteLines):
                lines.append(contentsOf: quoteLines.map { inline($0.text) })
            case .unorderedList(let items), .orderedList(let items):
                lines.append(contentsOf: items.map { inline($0) })
            case .table(let headers, _, let rows):
                lines.append(contentsOf: ([headers] + rows).flatMap { row in row.map { inline($0) } })
            case .columns(let columns):
                lines.append(contentsOf: columns.map { inline($0) })
            case .code(let language, let code):
                // Mermaid draws a diagram, not text.
                if MarkdownLanguage.normalized(language) != "mermaid" { lines.append(code) }
            case .image, .math, .divider:
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Projection cache keyed by message id; an entry is reused only while the
/// role, content and code are unchanged. `entries` keeps just the messages it
/// was given, so a session switch drops the old session's text.
@MainActor
final class MacChatFindTextCache {
    private struct Key: Equatable {
        let role: MessageRole
        let content: String
        let code: String?
    }

    private var storage: [String: (key: Key, text: String?)] = [:]

    private static func key(of message: ChatMessage) -> Key {
        Key(role: message.role, content: message.content, code: message.code)
    }

    func entries(for messages: [ChatMessage]) -> [MacChatFindEntry] {
        var next: [String: (key: Key, text: String?)] = [:]
        next.reserveCapacity(messages.count)
        var out: [MacChatFindEntry] = []
        for message in messages {
            let key = Self.key(of: message)
            let text: String?
            if let hit = storage[message.id], hit.key == key {
                text = hit.text
            } else {
                text = MacChatFindText.searchableText(for: message)
            }
            next[message.id] = (key, text)
            if let text { out.append(MacChatFindEntry(id: message.id, text: text)) }
        }
        storage = next
        return out
    }

    /// Fills the cache ahead of the first search without holding the main
    /// actor for long: yields after every `chunk` projections.
    func prime(_ messages: [ChatMessage], chunk: Int = 40) async {
        var computed = 0
        for message in messages {
            if Task.isCancelled { return }
            let key = Self.key(of: message)
            if let hit = storage[message.id], hit.key == key { continue }
            storage[message.id] = (key, MacChatFindText.searchableText(for: message))
            computed += 1
            if computed % chunk == 0 { await Task.yield() }
        }
    }
}
