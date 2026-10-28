import AppKit
import Foundation

/// What the print operation gets (D32).
struct MacChatPrintJob {
    /// The job title: the print panel shows it, and "Save as PDF" proposes it as the file name.
    var title: String
    var content: NSAttributedString
}

/// Runs the system print panel (D32), behind a seam so tests never show one.
@MainActor
protocol MacChatPrintRunning {
    func run(_ job: MacChatPrintJob, window: NSWindow?)
}

/// The system print panel as a sheet on the chat window; a plain panel when there is no window.
@MainActor
struct MacChatPrintRunner: MacChatPrintRunning {
    func run(_ job: MacChatPrintJob, window: NSWindow?) {
        let operation = MacChatPrintView.operation(for: job)
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

/// The print view and operation of a chat (D32): one `NSTextView` (TextKit 1) with black text on white, laid
/// out at the printable width, so `NSPrintOperation` splits it into pages. `NSTextView` moves a page break
/// off the middle of a line.
@MainActor
enum MacChatPrintView {
    static let margin: CGFloat = 54

    /// The operation with its print panel. A test turns the panel off and sends the pages to a file.
    static func operation(for job: MacChatPrintJob, printInfo: NSPrintInfo? = nil) -> NSPrintOperation {
        let info = (printInfo ?? NSPrintInfo.shared).copy() as? NSPrintInfo ?? NSPrintInfo()
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // A wider paper in the panel scales the page to fit it; the height takes as many pages as it needs.
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: view(for: job.content, printInfo: info), printInfo: info)
        operation.jobTitle = job.title
        return operation
    }

    static func view(for content: NSAttributedString, printInfo: NSPrintInfo) -> NSTextView {
        let width = max(printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin, 72)
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0), textContainer: container)
        view.isEditable = false
        view.isSelectable = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        // Light drawing and fixed colors, whatever the appearance of the app: dark mode prints the same.
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textColor = .black
        layout.ensureLayout(for: container)
        view.frame = NSRect(x: 0, y: 0, width: width, height: ceil(layout.usedRect(for: container).height))
        return view
    }
}

/// The attributed text of a printed chat (D32). Every color is fixed: black text, a light gray fill behind
/// code, no link color. Message text goes through the views' own Markdown parser, so headings, lists, quotes,
/// tables and code print as the chat shows them, as text only (pictures are not printed).
enum MacChatPrintContent {
    static let bodySize: CGFloat = 11
    static let codeBackground = NSColor(white: 0.93, alpha: 1)

    static func attributedString(_ document: MacChatExportDocument, strings: MacChatExportStrings) -> NSAttributedString {
        var writer = Writer()
        writer.paragraph(document.title, font: .systemFont(ofSize: 20, weight: .bold), after: 4)
        writer.paragraph(strings.exported(document.exported), font: .systemFont(ofSize: 10), after: 4)
        if document.olderOmitted {
            writer.paragraph(strings.olderNotIncluded, font: italic(.systemFont(ofSize: 10)), after: 4)
        }
        for item in document.items {
            switch item {
            case .message(let message):
                let heading = message.speaker + (message.time.map { "  (\($0))" } ?? "")
                writer.paragraph(heading, font: .systemFont(ofSize: 12, weight: .bold), before: 14, after: 3)
                writer.markdown(message.text)
                for name in message.attachments {
                    writer.paragraph(strings.attachment(name), font: .systemFont(ofSize: 10), after: 2)
                }
            case .tool(let step):
                let status = step.running ? strings.toolRunning : strings.toolComplete
                writer.paragraph(strings.toolLine(step.name, status), font: .systemFont(ofSize: 10), after: 2)
            }
        }
        return writer.result
    }

    // MARK: Writer

    private struct Writer {
        let result = NSMutableAttributedString()

        func paragraph(_ text: String, font: NSFont, before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0,
                       background: NSColor? = nil) {
            append(NSAttributedString(string: text, attributes: attributes(font: font, background: background)),
                   before: before, after: after, indent: indent)
        }

        /// One block: `text` plus the paragraph style, ended by a line break.
        func append(_ text: NSAttributedString, before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0,
                    hanging: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            let block = NSMutableAttributedString(attributedString: text)
            block.append(NSAttributedString(string: "\n", attributes: text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]))
            block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
            result.append(block)
        }

        func markdown(_ source: String) {
            guard !source.isEmpty else { return }
            let parsed = MarkdownParser.parseDocument(source)
            let body = NSFont.systemFont(ofSize: bodySize)
            func inline(_ text: String, font: NSFont = body) -> NSAttributedString {
                MacChatPrintContent.inline(text, references: parsed.references, font: font)
            }
            for block in parsed.blocks {
                switch block {
                case .heading(let level, let text):
                    let size = bodySize + CGFloat(max(0, 4 - level)) * 1.5
                    append(inline(text, font: .systemFont(ofSize: size, weight: .bold)), before: 6, after: 4)
                case .paragraph(let text):
                    append(inline(text))
                case .callout(let kind, let text):
                    append(inline(kind + ": " + text))
                case .quote(let lines):
                    for line in lines {
                        append(inline(line.text), after: 2, indent: 14 * CGFloat(max(line.depth, 1)))
                    }
                case .unorderedList(let items):
                    list(items, ordered: false, inline: { inline($0) })
                case .orderedList(let items):
                    list(items, ordered: true, inline: { inline($0) })
                case .table(let headers, _, let rows):
                    append(NSAttributedString(
                        string: headers.joined(separator: " | "),
                        attributes: attributes(font: .systemFont(ofSize: bodySize, weight: .bold))), after: 2)
                    for row in rows {
                        append(NSAttributedString(string: row.joined(separator: " | "), attributes: attributes(font: body)), after: 2)
                    }
                case .columns(let columns):
                    columns.forEach { append(inline($0)) }
                case .code(_, let code):
                    paragraph(code, font: .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular),
                              after: 8, indent: 6, background: codeBackground)
                case .math(let text):
                    paragraph(text, font: .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular))
                case .image(_, let alt):
                    if !alt.isEmpty { paragraph(alt, font: italic(body)) }
                case .divider:
                    paragraph("----------", font: body)
                case .htmlPreview:
                    break
                }
            }
        }

        private func list(_ items: [String], ordered: Bool, inline: (String) -> NSAttributedString) {
            for (index, item) in items.enumerated() {
                let task = MarkdownParser.taskItem(item)
                let marker: String
                if let task { marker = task.complete ? "[x] " : "[ ] " } else { marker = ordered ? "\(index + 1). " : "\u{2022} " }
                let line = NSMutableAttributedString(string: marker, attributes: attributes(font: .systemFont(ofSize: bodySize)))
                line.append(inline(task?.text ?? item))
                append(line, after: 2, indent: 8, hanging: 14)
            }
        }
    }

    // MARK: Inline

    private static func attributes(font: NSFont, background: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        if let background { out[.backgroundColor] = background }
        return out
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// Inline Markdown as text: bold, italic, code and strike-through kept, links underlined. A link prints with
    /// its address after it, because paper has no click.
    static func inline(_ source: String, references: MarkdownReferenceContext, font: NSFont) -> NSAttributedString {
        let attributed = InlineMarkdownContent.attributed(source: source, references: references)
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            if intent.contains(.stronglyEmphasized) { runFont = bold(runFont) }
            if intent.contains(.emphasized) { runFont = italic(runFont) }
            var attrs = attributes(font: runFont)
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                out.append(NSAttributedString(string: text, attributes: attrs))
                let address = link.absoluteString
                if ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? ""), address != text {
                    out.append(NSAttributedString(string: " (\(address))", attributes: attributes(font: runFont)))
                }
            } else {
                out.append(NSAttributedString(string: text, attributes: attrs))
            }
        }
        return out
    }
}
