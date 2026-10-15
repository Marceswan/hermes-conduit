import XCTest
import AppKit
import SwiftUI
@testable import UIKit
@testable import ConduitMac

/// Markdown lists on Mac: the bullet sits on its item's first text line, items
/// are spaced like lines of one list, wrapped lines hang under the text.
/// Hosts the real `MarkdownText` in a real window. Set
/// `TEST_RUNNER_CONDUIT_BULLET_SHOTS=<dir>` to also write PNGs (light + dark).
@MainActor
final class MarkdownListAlignmentTests: XCTestCase {
    static let message = "Important constraints:\n\n- A companion org can't connect to multiple home instances simultaneously.\n- You can't connect a production org to a sandbox through One.\n- An org already hosting Data Cloud requires cleanup/conversion before becoming a companion.\n\n**Bottom line:** keep the home org clean."

    private func host(_ source: String, width: CGFloat, dark: Bool, textSize: ChatTextSize = .default) -> NSWindow {
        let content = MarkdownText(source: source)
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.chatTextSize, textSize)
        let window = HostedTestSupport.host(content, size: NSSize(width: width, height: 700))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        HostedTestSupport.settle(0.3)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func shot(_ window: NSWindow, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["CONDUIT_BULLET_SHOTS"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let text = view as? NSTextView { found.append(text) }
        for sub in view.subviews { found += textViews(in: sub) }
        return found
    }

    /// Vertical centres (top-down, in points) of the accent-coloured marker
    /// glyphs left of `maxX`, one per row cluster.
    private func markerCenters(in window: NSWindow, maxX: CGFloat) throws -> [CGFloat] {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var hit = false
            for x in 0..<Int(maxX * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // The accent is orange/brown: clearly not a gray text pixel.
                if abs(c.redComponent - c.blueComponent) > 0.25 { hit = true; break }
            }
            if hit { rows.append(y) }
        }
        var clusters: [[Int]] = []
        for y in rows {
            if var last = clusters.last, let tail = last.last, y - tail <= 1 {
                last.append(y); clusters[clusters.count - 1] = last
            } else { clusters.append([y]) }
        }
        return clusters.map { CGFloat($0.reduce(0, +)) / CGFloat($0.count) / scale + 0.5 / scale }
    }

    /// The first line's vertical centre of `textView`, in the content view's
    /// top-down space.
    private func firstLineCenter(of textView: NSTextView, in window: NSWindow) throws -> CGFloat {
        let layout = try XCTUnwrap(textView.layoutManager)
        let rect = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        let host = try XCTUnwrap(window.contentView)
        return textView.convert(NSPoint(x: 0, y: rect.midY), to: host).y
    }

    private func assertMarkersCentered(_ source: String, items: [String], textSize: ChatTextSize = .default, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = host(source, width: 420, dark: false, textSize: textSize)
        defer { HostedTestSupport.tearDown(window) }
        let host = try XCTUnwrap(window.contentView)
        let itemViews = textViews(in: host).filter { view in items.contains { view.string.hasPrefix($0) } }
        XCTAssertEqual(itemViews.count, items.count, "list items must render as separate text views", file: file, line: line)
        let minX = try XCTUnwrap(itemViews.map { $0.convert($0.bounds, to: host).minX }.min())
        let centers = try markerCenters(in: window, maxX: minX - 1)
        XCTAssertEqual(centers.count, items.count, "one marker per item", file: file, line: line)
        for view in itemViews {
            let target = try firstLineCenter(of: view, in: window)
            let nearest = centers.min { abs($0 - target) < abs($1 - target) } ?? .infinity
            XCTAssertEqual(nearest, target, accuracy: 2, "marker must sit on the item's first line", file: file, line: line)
        }
    }

    /// A divider keeps the message out of the single flow text view, so the
    /// list renders through `MarkdownList` (marker + text view in an HStack).
    func testBulletsSitOnTheirItemsFirstLine() throws {
        for size in ChatTextSize.allCases {
            try assertMarkersCentered(Self.message + "\n\n---\n\nfin", items: [
                "A companion org", "You can't connect", "An org already"], textSize: size)
        }
    }

    func testOrderedMarkersSitOnTheirItemsFirstLine() throws {
        try assertMarkersCentered(
            "Steps:\n\n1. First thing to do, which is long enough that it wraps onto a second line.\n2. Second step here.\n3. Third.\n\n---\n\nfin",
            items: ["First thing", "Second step", "Third."])
    }

    func testItemSpacingIsOneLineAndABit() throws {
        let window = host(Self.message + "\n\n---\n\nfin", width: 420, dark: false)
        defer { HostedTestSupport.tearDown(window) }
        let host = try XCTUnwrap(window.contentView)
        let views = textViews(in: host).filter { $0.string.hasPrefix("You can't") || $0.string.hasPrefix("An org already") }
        let first = try XCTUnwrap(views.first { $0.string.hasPrefix("You can't") })
        let second = try XCTUnwrap(views.first { $0.string.hasPrefix("An org already") })
        let gap = second.convert(second.bounds, to: host).minY - first.convert(first.bounds, to: host).maxY
        XCTAssertLessThan(gap, 12, "items are separated by the list spacing, not a stray line")
    }

    /// Single flow text view: wrapped item lines hang under the item text.
    func testWrappedLinesHangUnderTheItemText() throws {
        let window = host(Self.message, width: 420, dark: false)
        defer { HostedTestSupport.tearDown(window) }
        let host = try XCTUnwrap(window.contentView)
        let flow = try XCTUnwrap(textViews(in: host).first { $0.string.contains("A companion org") })
        let layout = try XCTUnwrap(flow.layoutManager)
        let text = flow.string as NSString
        let wrapped = text.range(of: "simultaneously.")
        let glyph = layout.glyphIndexForCharacter(at: wrapped.location)
        let wrappedFragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let itemStart = text.range(of: "\u{2022} A companion").location
        let firstFragment = layout.lineFragmentRect(
            forGlyphAt: layout.glyphIndexForCharacter(at: itemStart), effectiveRange: nil)
        XCTAssertGreaterThan(wrappedFragment.minY, 0)
        XCTAssertGreaterThan(wrappedFragment.minY, firstFragment.minY, "the item must really wrap")
        let style = try XCTUnwrap(flow.textStorage?.attribute(.paragraphStyle, at: itemStart, effectiveRange: nil) as? NSParagraphStyle)
        let markerWidth = ceil(("\u{2022} " as NSString).size(withAttributes: [.font: ChatTypography.font(for: .body, chatSize: .default).withTraits(.traitBold)]).width)
        let x = layout.location(forGlyphAt: glyph).x + wrappedFragment.minX
        XCTAssertEqual(style.headIndent, markerWidth, accuracy: 1)
        XCTAssertEqual(x, markerWidth, accuracy: 1, "wrapped line must start at the marker width")
    }

    func testShots() throws {
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            for (name, src) in [("bullets", Self.message),
                                ("bullets-rich", Self.message + "\n\n---\n\nfin"),
                                ("ordered-rich", "Steps:\n\n1. First thing to do, which is long enough that it wraps onto a second line in the window.\n2. Second.\n\n---\n\nfin"),
                                ("ordered", "Steps:\n\n1. First thing to do, which is long enough that it wraps onto a second line in the window.\n2. Second.\n3. Third.\n\nDone."),
                                ("nested", "Top:\n\n- one\n  - nested a\n  - nested b\n- two\n\nEnd.")] {
                let w = host(src, width: 420, dark: dark)
                try shot(w, name: "\(name)-\(tag)")
                HostedTestSupport.tearDown(w)
            }
        }
    }
}
