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
        let textView = NSTextView(frame: .zero)
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

    static func measuredHeight(
        of text: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int = 0
    ) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumNumberOfLines
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func styledText() -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: attributedText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = wrapsLines ? .byWordWrapping : .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
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
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        if let range = selfSizingWidthRange {
            let natural = ceil(styledText().size().width)
            let width = min(max(natural, range.lowerBound), range.upperBound)
            return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
        }
        let width = proposal.width ?? 600
        return CGSize(width: width, height: Self.measuredHeight(of: styledText(), width: width, maximumNumberOfLines: maximumNumberOfLines))
    }

    /// R11: link clicks never reach NSTextView's default NSWorkspace handling.
    /// They go through `UIApplication.shared.open`, which applies the scheme
    /// allowlist.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
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
            if let url = Self.url(fromLink: link) { opener(url) }
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
