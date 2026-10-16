import AppKit

enum MacChatFindColors {
    static let match = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.35, alpha: 1)
    static let current = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1)
    static let text = NSColor.black

    /// WCAG contrast ratio of two colors (sRGB).
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}

/// Highlights are TextKit 1 temporary attributes: the text storage, measuring
/// (D13), selection and accessibility never see them. Only the ranges this
/// type applied are removed, so link styling the text view keeps as temporary
/// attributes elsewhere is untouched.
@MainActor
enum MacChatFindHighlighter {
    /// Returns the ranges it applied (clamped to the text). `current` indexes `ranges`.
    @discardableResult
    static func apply(
        to textView: NSTextView,
        ranges: [NSRange],
        current: Int?,
        replacing previous: [NSRange]
    ) -> [NSRange] {
        guard textView.textLayoutManager == nil, let layout = textView.layoutManager else { return [] }
        let length = (textView.string as NSString).length
        clear(layout, ranges: previous, length: length)
        var applied: [NSRange] = []
        for (index, raw) in ranges.enumerated() {
            let range = NSIntersectionRange(raw, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layout.addTemporaryAttributes(
                [
                    .backgroundColor: index == current ? MacChatFindColors.current : MacChatFindColors.match,
                    .foregroundColor: MacChatFindColors.text,
                ],
                forCharacterRange: range
            )
            applied.append(range)
        }
        return applied
    }

    static func clear(_ textView: NSTextView, ranges: [NSRange]) {
        guard textView.textLayoutManager == nil, let layout = textView.layoutManager else { return }
        clear(layout, ranges: ranges, length: (textView.string as NSString).length)
    }

    private static func clear(_ layout: NSLayoutManager, ranges: [NSRange], length: Int) {
        for raw in ranges {
            let range = NSIntersectionRange(raw, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
    }
}

enum MacChatFindScroll {
    /// The find bar covers the top of the transcript.
    static let barHeight: CGFloat = 48
    static let bottomMargin: CGFloat = 16
    static let anchorFraction: CGFloat = 0.35

    /// The clip-view y origin that brings `rect` (document coordinates, flipped:
    /// y grows downward) into the comfortable band, or nil when it already
    /// sits there or the offset would not change.
    static func targetOffset(
        rect: CGRect,
        offset: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat
    ) -> CGFloat? {
        let top = offset + barHeight
        let bottom = offset + viewportHeight - bottomMargin
        if rect.minY >= top, rect.maxY <= bottom { return nil }
        let desired = rect.midY - viewportHeight * anchorFraction
        let maxOffset = max(0, documentHeight - viewportHeight)
        let clamped = min(max(0, desired), maxOffset)
        return abs(clamped - offset) < 0.5 ? nil : clamped
    }

    /// The transcript's scroll view for `view`: the OUTERMOST `NSScrollView`
    /// above it. Code blocks and table cells sit in their own horizontal
    /// `ScrollView`, so `enclosingScrollView` would name that inner one and the
    /// vertical transcript would never move.
    @MainActor
    static func transcriptScrollView(containing view: NSView) -> NSScrollView? {
        scrollViews(above: view).last
    }

    /// Every `NSScrollView` above `view`, innermost first.
    @MainActor
    private static func scrollViews(above view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        var node = view.superview
        while let current = node {
            if let scroll = current as? NSScrollView { out.append(scroll) }
            node = current.superview
        }
        return out
    }

    /// The clip-view x origin that brings `rect` (document coordinates) fully
    /// into a clip of `viewportWidth`, or nil when it is already visible.
    static func targetOffsetX(
        rect: CGRect,
        offset: CGFloat,
        viewportWidth: CGFloat,
        documentWidth: CGFloat
    ) -> CGFloat? {
        if rect.minX >= offset, rect.maxX <= offset + viewportWidth { return nil }
        let maxOffset = max(0, documentWidth - viewportWidth)
        let desired = rect.minX < offset ? rect.minX - 16 : rect.maxX - viewportWidth + 16
        let clamped = min(max(0, desired), maxOffset)
        return abs(clamped - offset) < 0.5 ? nil : clamped
    }

    /// Scrolls the transcript's `NSScrollView` so `range` of `view` is visible,
    /// and any inner horizontal scroll view (code block, table) so the hit is
    /// horizontally visible too.
    /// A bounds change the scroll surface did not write is read as the reader
    /// browsing (ChatScrollSurfaceLocator.classifyScroll), so the engine does
    /// not snap back to the latest message.
    @MainActor
    static func reveal(_ range: NSRange, in view: NSTextView) {
        guard view.textLayoutManager == nil, let layout = view.layoutManager,
              let container = view.textContainer else { return }
        let scrollers = scrollViews(above: view)
        guard let scroll = scrollers.last, let document = scroll.documentView else { return }
        // An out-of-range character range raises NSRangeException in AppKit.
        let range = NSIntersectionRange(range, NSRange(location: 0, length: (view.string as NSString).length))
        guard range.length > 0 else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        // Inner scroll views first (innermost to outermost, excluding the
        // transcript): moving them changes only x, so the vertical math below
        // is unaffected.
        for inner in scrollers.dropLast() {
            guard let innerDocument = inner.documentView else { continue }
            let clip = inner.contentView
            let inInner = innerDocument.convert(rect, from: view)
            guard let x = targetOffsetX(
                rect: inInner,
                offset: clip.bounds.origin.x,
                viewportWidth: clip.bounds.width,
                documentWidth: innerDocument.frame.width
            ) else { continue }
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
            inner.reflectScrolledClipView(clip)
        }
        let inDocument = document.convert(rect, from: view)
        let clip = scroll.contentView
        guard let y = targetOffset(
            rect: inDocument,
            offset: clip.bounds.origin.y,
            viewportHeight: clip.bounds.height,
            documentHeight: document.frame.height
        ) else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

/// The mounted message text views of one window, keyed by message id (D23).
/// Views register from `SelectableTextView.updateNSView` and unregister from
/// `dismantleNSView`; the registry holds them weakly.
@MainActor
final class MacChatFindRegistry {
    struct Context: Equatable {
        var query: String
        var current: MacChatFindMatch?
        /// Ids of the messages the model searches; other rows are never highlighted.
        var searchable: Set<String>
    }

    private final class Entry {
        weak var view: NSTextView?
        let messageID: String
        var highlighted: [NSRange] = []

        init(view: NSTextView, messageID: String) {
            self.view = view
            self.messageID = messageID
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) var context: Context?
    /// Called after a view registers (also when it registers again with new
    /// text), with its message id.
    var didRegister: ((String) -> Void)?

    func register(_ view: NSTextView, messageID: String) {
        let key = ObjectIdentifier(view)
        if let existing = entries[key], existing.messageID == messageID, existing.view === view {
            // Same view again (text may have changed): keep the ranges to clear.
        } else {
            entries[key] = Entry(view: view, messageID: messageID)
        }
        if context != nil { refresh(messageID: messageID) }
        didRegister?(messageID)
    }

    func unregister(_ view: NSTextView) {
        entries[ObjectIdentifier(view)] = nil
    }

    var mountedViewCount: Int { liveEntries().count }

    /// Reading order: top to bottom, then left to right.
    func views(for messageID: String) -> [NSTextView] {
        liveEntries()
            .filter { $0.messageID == messageID }
            .compactMap(\.view)
            .sorted(by: Self.readingOrder)
    }

    /// The transcript: the outermost scroll view above the topmost live view
    /// (reading order, not dictionary order), so routing is deterministic.
    var transcriptScrollView: NSScrollView? {
        liveEntries()
            .compactMap(\.view)
            .sorted(by: Self.readingOrder)
            .lazy
            .compactMap { MacChatFindScroll.transcriptScrollView(containing: $0) }
            .first
    }

    /// True for a message view and for anything inside the transcript scroll view.
    func contains(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        if liveEntries().contains(where: { $0.view === view }) { return true }
        guard let scroll = transcriptScrollView else { return false }
        return view.isDescendant(of: scroll)
    }

    func setContext(_ context: Context?) {
        // `register` refreshes a new or re-registered view itself.
        guard context != self.context else { return }
        self.context = context
        for id in Set(liveEntries().map(\.messageID)) { refresh(messageID: id) }
    }

    private func liveEntries() -> [Entry] {
        for (key, entry) in entries where entry.view == nil { entries[key] = nil }
        return Array(entries.values)
    }

    /// The mounted view and view-local range of hit number `ordinal` of
    /// `messageID` for `query`, from the same per-view matching `refresh`
    /// paints with. nil when the query is not searchable, the message has no
    /// mounted view, or the ordinal is past what the views draw.
    func target(messageID: String, ordinal: Int, query: String) -> (view: NSTextView, range: NSRange)? {
        guard MacChatFindMatcher.isSearchable(query) else { return nil }
        let views = group(messageID).map(\.view)
        let ranges = views.map { MacChatFindMatcher.ranges(of: query, in: $0.string) }
        guard let spot = Self.locate(ordinal: ordinal, counts: ranges.map(\.count)) else { return nil }
        return (views[spot.view], ranges[spot.view][spot.local])
    }

    private func group(_ messageID: String) -> [(entry: Entry, view: NSTextView)] {
        liveEntries()
            .filter { $0.messageID == messageID }
            .compactMap { entry in entry.view.map { (entry: entry, view: $0) } }
            .sorted { Self.readingOrder($0.view, $1.view) }
    }

    /// Re-highlights every view of one message: ranges per view, then the
    /// current hit mapped to (view, local index) by reading order.
    private func refresh(messageID: String) {
        let group = self.group(messageID)
        guard let context, MacChatFindMatcher.isSearchable(context.query),
              context.searchable.contains(messageID) else {
            for item in group {
                MacChatFindHighlighter.clear(item.view, ranges: item.entry.highlighted)
                item.entry.highlighted = []
            }
            return
        }
        let ranges = group.map { MacChatFindMatcher.ranges(of: context.query, in: $0.view.string) }
        var spot: (view: Int, local: Int)?
        if let current = context.current, current.messageID == messageID {
            spot = Self.locate(ordinal: current.ordinal, counts: ranges.map(\.count))
        }
        for (index, item) in group.enumerated() {
            item.entry.highlighted = MacChatFindHighlighter.apply(
                to: item.view,
                ranges: ranges[index],
                current: spot?.view == index ? spot?.local : nil,
                replacing: item.entry.highlighted
            )
        }
    }

    static func readingOrder(_ a: NSTextView, _ b: NSTextView) -> Bool {
        let pa = topLeft(of: a)
        let pb = topLeft(of: b)
        if abs(pa.y - pb.y) > 1 { return pa.y > pb.y }   // window space: larger y is higher
        return pa.x < pb.x
    }

    private static func topLeft(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY), to: nil)
    }

    /// Maps a message-wide ordinal to (view index, hit index inside that view).
    static func locate(ordinal: Int, counts: [Int]) -> (view: Int, local: Int)? {
        guard ordinal >= 0 else { return nil }
        var remaining = ordinal
        for (index, count) in counts.enumerated() {
            if remaining < count { return (index, remaining) }
            remaining -= count
        }
        return nil
    }
}
