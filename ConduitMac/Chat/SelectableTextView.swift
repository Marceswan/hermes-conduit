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
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
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
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
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
            selectionSegment: selectionSegment
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
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
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
            selectionSegment: selectionSegment
        )
    }
}

extension SelectableTextView {
    static func makeTextView(delegate: NSTextViewDelegate? = nil) -> NSTextView {
        // TextKit 1 on purpose. `measuredHeight` (what `sizeThatFits` returns)
        // lays text out with an NSLayoutManager; a plain `NSTextView(frame:)`
        // is TextKit 2 on macOS 13+, whose last line fragment is taller (it
        // includes the trailing line spacing), so the SwiftUI frame came out
        // short and the final line was clipped (D13). One engine for measuring
        // and drawing keeps the two equal by construction.
        let textView = NSTextView(usingTextLayoutManager: false)
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
        // Paragraph styles the caller set (list hanging indents) are kept;
        // the view's spacing, alignment and wrapping fill in on top.
        var paragraphRuns: [(NSRange, NSParagraphStyle?)] = []
        styled.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, subrange, _ in
            paragraphRuns.append((subrange, value as? NSParagraphStyle))
        }
        for (subrange, existing) in paragraphRuns {
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
        if view.attributedString() != styled {
            view.textStorage?.setAttributedString(styled)
        }
        view.textContainer?.maximumNumberOfLines = maximumNumberOfLines
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        context.coordinator.openURL = context.environment.openURL
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
        private let opener: @MainActor (URL) -> Void

        init(opener: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }) {
            self.opener = opener
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
