import AppKit
import SwiftUI

// Mac twin of SelectableTextView.swift SelectableTextView; keep in sync (PORTING_LEDGER).
/// NSTextView-backed selectable text. The initializers and `bridge` match
/// upstream so call sites compile unchanged. `selectionCoordinator` and
/// `selectionSegment` are accepted and ignored: selection is native NSTextView
/// selection on Mac.
struct SelectableTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int
    let wrapsLines: Bool
    let linkColor: NSColor
    let textAlignment: NSTextAlignment
    let selfSizingWidthRange: ClosedRange<CGFloat>?
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?
    /// Keeps the paragraph styles the text carries exactly as they are (spacing, indents, tab
    /// stops, alignment, line break mode); paragraphs with none get the view's values.
    let keepsParagraphStyles: Bool

    init(
        attributedText: NSAttributedString,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil,
        keepsParagraphStyles: Bool = false
    ) {
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.wrapsLines = wrapsLines
        self.linkColor = linkColor
        self.textAlignment = textAlignment
        self.selfSizingWidthRange = selfSizingWidthRange
        self.selectionCoordinator = selectionCoordinator
        self.selectionSegment = selectionSegment
        self.keepsParagraphStyles = keepsParagraphStyles
    }

    init(
        attributedText: AttributedString,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil,
        keepsParagraphStyles: Bool = false
    ) {
        self.init(
            attributedText: Self.bridge(attributedText, defaultFont: font, defaultColor: textColor, linkColor: linkColor),
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            linkColor: linkColor,
            textAlignment: textAlignment,
            selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment,
            keepsParagraphStyles: keepsParagraphStyles
        )
    }

    init(
        text: String,
        font: NSFont = .preferredFont(forTextStyle: .body),
        textColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: NSColor = .linkColor,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil,
        keepsParagraphStyles: Bool = false
    ) {
        self.init(
            attributedText: NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: textColor]
            ),
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            linkColor: linkColor,
            textAlignment: textAlignment,
            selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment,
            keepsParagraphStyles: keepsParagraphStyles
        )
    }
}

extension SelectableTextView {
    /// The text view. A chat answer's prose run (`MarkdownProseRun`) keeps a
    /// tab after each list marker and one line break between blocks, marked
    /// with `MarkdownProseRun.copiesAs`; upstream copies them as a space and a
    /// blank line. A plain NSTextView would copy the raw characters, so Copy,
    /// drag and Services read the selection through `copyableText` here. Text
    /// with no marks copies as NSTextView does.
    final class ProseCopyTextView: NSTextView {
        /// Where Copy writes a marked selection. Tests replace it.
        var pasteboard: NSPasteboard = .general

        /// What copying the selection gives, when it holds marked characters.
        func copiedSelection() -> NSAttributedString? {
            let range = NSIntersectionRange(selectedRange(), NSRange(location: 0, length: textStorage?.length ?? 0))
            guard range.length > 0, let text = textStorage?.attributedSubstring(from: range) else { return nil }
            let copied = MarkdownProseRun.copyableText(text)
            return copied === text ? nil : copied
        }

        override func copy(_ sender: Any?) {
            guard let copied = copiedSelection() else {
                super.copy(sender)
                return
            }
            // String-only, as upstream's UITextView copy writes it.
            pasteboard.clearContents()
            pasteboard.setString(copied.string, forType: .string)
        }

        override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            guard let copied = copiedSelection() else {
                return super.writeSelection(to: pboard, types: types)
            }
            pboard.declareTypes([.string], owner: nil)
            return pboard.setString(copied.string, forType: .string)
        }
    }

    static func makeTextView(delegate: NSTextViewDelegate? = nil) -> NSTextView {
        // TextKit 1 on purpose. `measuredHeight` (what `sizeThatFits` returns)
        // lays text out with an NSLayoutManager; a plain `NSTextView(frame:)`
        // is TextKit 2 on macOS 13+, whose last line fragment is taller (it
        // includes the trailing line spacing), so the SwiftUI frame came out
        // short and the final line was clipped (D13). One engine for measuring
        // and drawing keeps the two equal by construction.
        let textView = ProseCopyTextView(usingTextLayoutManager: false)
        textView.delegate = delegate
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    /// How much of the tint a selection on an accent surface shows: enough to
    /// read against the bubble, not so much that it hides the text.
    private static let selectionTintAlpha: CGFloat = 0.3

    private static let systemSelectedTextAttributes = makeTextView().selectedTextAttributes

    /// A selection on a sent bubble would take the bubble's own colour, the
    /// accent, and disappear (#697, #702). `MarkdownText` puts a contrasting
    /// tint in the environment (`textSelectionTint`); a view that gets one
    /// highlights its selection in it, and one that gets none uses the system
    /// colour again. Static so `Context` is not needed to test it.
    static func applySelectionTint(_ tint: NSColor?, to textView: NSTextView) {
        guard let tint else {
            if !NSDictionary(dictionary: textView.selectedTextAttributes).isEqual(to: systemSelectedTextAttributes) {
                textView.selectedTextAttributes = systemSelectedTextAttributes
            }
            return
        }
        // A dynamic colour is resolved for the view's own appearance.
        var resolved = tint
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = tint.usingColorSpace(.sRGB) ?? tint
        }
        let background = resolved.withAlphaComponent(selectionTintAlpha)
        guard (textView.selectedTextAttributes[.backgroundColor] as? NSColor) != background else { return }
        var attributes = systemSelectedTextAttributes
        attributes[.backgroundColor] = background
        textView.selectedTextAttributes = attributes
    }

    /// The one TextKit 1 layout setup that measuring and baseline lookup share.
    /// The caller keeps `storage` alive for as long as it uses `layout`.
    private static func laidOutText(
        _ text: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int = 0
    ) -> (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumNumberOfLines
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return (storage, layout, container)
    }

    static func measuredHeight(
        of text: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int = 0
    ) -> CGFloat {
        let laidOut = laidOutText(text, width: width, maximumNumberOfLines: maximumNumberOfLines)
        return ceil(laidOut.layout.usedRect(for: laidOut.container).height)
    }

    /// Distance from the top of the text to the first line's baseline at
    /// `width`, as upstream's UITextView exposes through its first-baseline
    /// alignment. An NSViewRepresentable has no baseline of its own, so a
    /// `.firstTextBaseline` HStack (list bullets) fell back to the view's
    /// bottom edge and the marker floated a line above its text.
    func firstBaseline(width: CGFloat) -> CGFloat {
        let styled = styledText()
        guard styled.length > 0 else { return ceil(font.ascender) }
        let laidOut = Self.laidOutText(styled, width: max(1, width))
        let fragment = laidOut.layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return fragment.minY + laidOut.layout.location(forGlyphAt: 0).y
    }

    /// Publishes `firstBaseline(width:)` as this view's `.firstTextBaseline`.
    func firstBaselineAligned() -> some View {
        alignmentGuide(.firstTextBaseline) { dimensions in
            firstBaseline(width: dimensions.width)
        }
    }

    func styledText() -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: styled.length)
        guard fullRange.length > 0 else { return styled }
        // With `keepsParagraphStyles`, a paragraph that has a style stays exactly
        // as the caller made it (upstream `applyParagraphStyle`): a prose run
        // sets its own spacing, indents and tab stops. One that has none gets
        // the view's line spacing, alignment and wrapping.
        // Mac difference, without the flag: upstream replaces the whole style;
        // here a caller's style is copied and only the line spacing,
        // alignment and wrapping are set on it, because the Mac list region of
        // `MarkdownSelectionFormatter.list` (MarkdownText.swift) sets a
        // hanging indent that must survive.
        var paragraphRuns: [(NSRange, NSParagraphStyle?)] = []
        styled.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, subrange, _ in
            paragraphRuns.append((subrange, value as? NSParagraphStyle))
        }
        for (subrange, existing) in paragraphRuns {
            if keepsParagraphStyles, existing != nil { continue }
            let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.alignment = textAlignment
            paragraph.lineBreakMode = wrapsLines ? .byWordWrapping : .byTruncatingTail
            styled.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
        }
        // Same fill as upstream configure(_:): per-run font and color win,
        // the configured defaults fill only what is missing.
        styled.enumerateAttribute(.font, in: fullRange, options: []) { value, subrange, _ in
            if value == nil {
                styled.addAttribute(.font, value: font, range: subrange)
            }
        }
        styled.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, subrange, _ in
            if value == nil {
                styled.addAttribute(.foregroundColor, value: textColor, range: subrange)
            }
        }
        return styled
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = Self.makeTextView(delegate: context.coordinator)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let styled = styledText()
        let textChanged = view.attributedString() != styled
        if textChanged {
            view.textStorage?.setAttributedString(styled)
        }
        view.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        Self.applySelectionTint(context.environment.textSelectionTint, to: view)
        context.coordinator.openURL = context.environment.openURL
        // D23: whole-chat find registers each message text view under its row id.
        context.coordinator.attachFind(
            view,
            controller: context.environment.macChatFindController,
            messageID: context.environment.macChatFindMessageID,
            textChanged: textChanged
        )
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        coordinator.findController?.registry.unregister(view)
        coordinator.findController = nil
        coordinator.findMessageID = nil
    }

    /// Mirrors upstream `measureNonWrapping`: the text's natural single-line size.
    func measureNonWrapping() -> CGSize {
        let measured = styledText().boundingRect(
            with: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(width: max(1, ceil(measured.width)), height: max(ceil(lineHeight), ceil(measured.height)))
    }

    /// Shared by `sizeThatFits` and tests (`Context` cannot be built outside
    /// SwiftUI). Branch order and the `width > 0, width.isFinite` guard match
    /// upstream `measuredSize(proposalWidth:textView:)`. Upstream returns nil
    /// for an unusable wrapping proposal; AppKit has no fallback height, so
    /// that case measures at the natural width instead.
    func measuredSize(proposalWidth: CGFloat?) -> CGSize {
        if !wrapsLines {
            return measureNonWrapping()
        }
        if let range = selfSizingWidthRange {
            let idealWidth = max(1, measureNonWrapping().width)
            let width = min(max(idealWidth, range.lowerBound), range.upperBound)
            return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
        }
        let width: CGFloat
        if let proposed = proposalWidth, proposed > 0, proposed.isFinite {
            width = proposed
        } else {
            width = max(1, measureNonWrapping().width)
        }
        return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        measuredSize(proposalWidth: proposal.width)
    }

    /// R11/R27: link clicks never reach NSTextView's default NSWorkspace
    /// handling. They go to the environment `OpenURLAction` (root policy
    /// `MacOpenURLPolicy` routes in-app links and applies the allowlist). Only
    /// when no action was captured do they fall back to
    /// `UIApplication.shared.open`, which applies the same scheme allowlist.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        weak var findController: MacChatFindController?
        var findMessageID: String?
        private let opener: @MainActor (URL) -> Void

        init(opener: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }) {
            self.opener = opener
        }

        /// Registers when the view sits in a transcript row of a window with
        /// whole-chat find; otherwise makes sure it is not registered. Runs on
        /// every `updateNSView`, so it registers again only when something
        /// changed (controller, row id, or the text, whose highlights must be
        /// repainted); the registry fires `didRegister` on every call.
        func attachFind(_ view: NSTextView, controller: MacChatFindController?, messageID: String?, textChanged: Bool = true) {
            if let controller, let messageID {
                if findController === controller, findMessageID == messageID, !textChanged { return }
                if let old = findController, old !== controller { old.registry.unregister(view) }
                findController = controller
                findMessageID = messageID
                controller.registry.register(view, messageID: messageID)
            } else if let old = findController {
                old.registry.unregister(view)
                findController = nil
                findMessageID = nil
            }
        }

        static func url(fromLink link: Any) -> URL? {
            if let url = link as? URL { return url }
            if let string = link as? String { return URL(string: string) }
            return nil
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = Self.url(fromLink: link) else { return true }
            if let openURL {
                openURL(url)
            } else {
                opener(url)
            }
            return true
        }
    }
}

// Copied from upstream SelectableTextView.swift; keep in sync.
extension SelectableTextView {
    /// Converts an AttributedString (from Markdown parsing) into an
    /// NSAttributedString with UIKit-compatible font traits. Exposed as
    /// internal so callers can convert without instantiating the full view.
    static func bridge(
        _ value: AttributedString,
        defaultFont: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor
    ) -> NSAttributedString {
        let bridged = NSMutableAttributedString(
            string: String(value.characters),
            attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ]
        )

        for run in value.runs {
            let range = NSRange(run.range, in: value)
            guard range.length > 0 else { continue }

            if let intent = run.inlinePresentationIntent {
                var runFont = defaultFont
                if intent.contains(.stronglyEmphasized) {
                    runFont = runFont.withTraits(.traitBold)
                }
                if intent.contains(.emphasized) {
                    runFont = runFont.withTraits(.traitItalic)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: defaultFont.pointSize, weight: .regular)
                }
                bridged.addAttribute(.font, value: runFont, range: range)
                if intent.contains(.strikethrough) {
                    bridged.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
            }

            if let runColor = run.foregroundColor {
                bridged.addAttribute(.foregroundColor, value: UIColor(runColor), range: range)
            }
            if let link = run.link {
                bridged.addAttribute(.link, value: link, range: range)
                bridged.addAttribute(.foregroundColor, value: linkColor, range: range)
            }
        }
        return bridged
    }
}

// Adapted from upstream SelectableTextView.swift; keep in sync.
extension UIFont {
    /// Returns a font with the requested symbolic traits merged into the
    /// existing set, so chained calls (e.g. bold then italic) accumulate
    /// rather than replacing the entire trait collection.
    /// Mac difference: NSFontDescriptor.withSymbolicTraits is non-optional
    /// and NSFont(descriptor:size:) is the optional one.
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return UIFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// keep in sync: Conduit/Views/Components/SelectableTextView.swift (a chat sets it so text draws
// without a text view until touched). The Mac text view ignores it.
private struct SelectableTextDrawsUntilTouchedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var selectableTextDrawsUntilTouched: Bool {
        get { self[SelectableTextDrawsUntilTouchedKey.self] }
        set { self[SelectableTextDrawsUntilTouchedKey.self] = newValue }
    }
}

private struct TextSelectionTintKey: EnvironmentKey {
    static let defaultValue: UIColor? = nil
}

extension EnvironmentValues {
    /// The selection tint for chat text on a coloured surface (#697). The Mac text view
    /// highlights its selection in it (`SelectableTextView.applySelectionTint`).
    var textSelectionTint: UIColor? {
        get { self[TextSelectionTintKey.self] }
        set { self[TextSelectionTintKey.self] = newValue }
    }
}
