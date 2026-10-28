import Foundation

/// The default name of an exported chat (D32): the chat title made safe for a file name, a space, the
/// date, and ".md". The title comes from the host or the agent, so it is data: it never keeps a path
/// separator, a control or format character, a leading dot, or more than `maxTitleGraphemes` characters.
/// The user still picks the folder and can change the name in the save panel.
enum MacChatExportFileName {
    static let maxTitleGraphemes = 80
    /// The title part in UTF-8 bytes. A file name may have 255; the date and the extension take 14.
    static let maxTitleBytes = 180

    /// "Weekend trip 2026-10-28.md".
    static func make(
        title: String?, date: Date, fallback: String, pathExtension: String = "md", timeZone: TimeZone = .current
    ) -> String {
        baseName(title: title, date: date, fallback: fallback, timeZone: timeZone) + "." + pathExtension
    }

    /// "Weekend trip 2026-10-28". The print job uses it as its title, so "Save as PDF" proposes it.
    static func baseName(title: String?, date: Date, fallback: String, timeZone: TimeZone = .current) -> String {
        var text = safe(title ?? "")
        if text.isEmpty { text = safe(fallback) }
        if text.isEmpty { text = "Chat" }
        return text + " " + day(date, timeZone: timeZone)
    }

    private static func day(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func safe(_ raw: String) -> String {
        // Control and format characters (a right-to-left override can spoof an extension) are dropped and
        // line breaks and tabs become spaces.
        var text = MacUntrustedText.sanitize(raw, maxGraphemes: 200)
        text = String(text.filter { !"*?\"<>|".contains($0) })
        text = String(text.map { "/:\\".contains($0) ? "-" : $0 })
        text = text.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = String(text.prefix(maxTitleGraphemes))
        while text.utf8.count > maxTitleBytes { text.removeLast() }
        return trimmed(text)
    }

    /// Without spaces, dots and dashes at both ends: no hidden file, no ".." and no dangling dash.
    private static func trimmed(_ text: String) -> String {
        let edge: (Character) -> Bool = { $0 == " " || $0 == "." || $0 == "-" || $0.isWhitespace }
        var characters = Substring(text)
        while let first = characters.first, edge(first) { characters.removeFirst() }
        while let last = characters.last, edge(last) { characters.removeLast() }
        return String(characters)
    }
}
