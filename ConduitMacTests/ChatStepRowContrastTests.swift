import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Light- and dark-mode contrast of the chat step rows upstream drew in 2.x
/// (#645, #651, #1063, #1074): the tool row, the thinking row and the header of
/// a run of steps. Each text element must reach 4.5:1 against its own surface
/// and each chevron 3:1 (Ruling R20), measured from rendered pixels.
///
/// The method is the one of `ComposerToolCardContrastTests`: `ImageRenderer` at
/// 4x with the app's root tint (`.conduitAccent`, which turns a hierarchical
/// `.secondary` inside a button label into a faded gold) on an opaque
/// background. The best pixel of the ink rectangle is compared with the fill
/// sample beside it; the fill must be one neutral colour, and the ink rectangle
/// must hold enough differing pixels, so a layout shift cannot pass vacuously.
///
/// Not measured, because `ImageRenderer` does not paint an `NSViewRepresentable`:
/// the raw input and output text, the open thinking text and diff text
/// (`SelectableTextView`) and the running spinner (`ProgressView`).
///
/// Set `TEST_RUNNER_CONTRAST_SHOTS_DIR=<dir>` to also write the PNGs.
@MainActor
final class ChatStepRowContrastTests: XCTestCase {
    private static let renderScale: CGFloat = 4
    private static let width: CGFloat = 420

    // MARK: Measuring (as ComposerToolCardContrastTests)

    private func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .tint(.conduitAccent)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.12) : Color.white))
        renderer.scale = Self.renderScale
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    private func shoot(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CONTRAST_SHOTS_DIR"],
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    struct Measurement {
        var ratio: Double
        var differingPixels: Int
        var fillIsUniform: Bool
        var fillIsNeutral: Bool
    }

    private func measure(_ rep: NSBitmapImageRep, pointsWide: CGFloat, ink: CGRect, fill: CGPoint) -> Measurement {
        let scale = CGFloat(rep.pixelsWide) / pointsWide
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double)? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }

        let cx = Int(fill.x * scale), cy = Int(fill.y * scale)
        var block: [(r: Double, g: Double, b: Double)] = []
        for dx in -2...2 { for dy in -2...2 { if let c = rgb(cx + dx, cy + dy) { block.append(c) } } }
        let base = block.first ?? (r: 0, g: 0, b: 0)
        let uniform = block.count == 25 && block.allSatisfy {
            abs($0.r - base.r) < 0.02 && abs($0.g - base.g) < 0.02 && abs($0.b - base.b) < 0.02
        }
        let neutral = (base.r - base.b) < 0.12 && (base.g - base.b) < 0.12

        let bgLum = luminance(base)
        var best = 1.0
        var differing = 0
        for x in Int(ink.minX * scale)..<Int(ink.maxX * scale) {
            for y in Int(ink.minY * scale)..<Int(ink.maxY * scale) {
                guard let c = rgb(x, y) else { continue }
                let l = luminance(c)
                if abs(l - bgLum) > 0.05 { differing += 1 }
                best = max(best, (max(l, bgLum) + 0.05) / (min(l, bgLum) + 0.05))
            }
        }
        return Measurement(ratio: best, differingPixels: differing,
                           fillIsUniform: uniform, fillIsNeutral: neutral)
    }

    /// With `CONTRAST_SHOTS_DIR` set, appends each ratio to `ratios.txt` there.
    private func record(_ m: Measurement, _ name: String, target: Double) {
        guard let dir = ProcessInfo.processInfo.environment["CONTRAST_SHOTS_DIR"] else { return }
        let line = "\(name)\t\(String(format: "%.2f", m.ratio))\t\(target)\n"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: "\(dir)/ratios.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func check(_ m: Measurement, _ name: String, target: Double) {
        record(m, name, target: target)
        XCTAssertTrue(m.fillIsUniform, "\(name): fill sample is not a uniform surface")
        XCTAssertTrue(m.fillIsNeutral, "\(name): fill sample is not a neutral surface")
        XCTAssertGreaterThanOrEqual(m.differingPixels, 10, "\(name): too few ink pixels differ from the fill")
        XCTAssertGreaterThanOrEqual(m.ratio, target, "\(name): contrast \(String(format: "%.2f", m.ratio)):1, need \(target):1")
    }

    // MARK: Fixtures

    /// One thing to measure in a fixture: ink rectangle and fill point, in points.
    private struct Element {
        let name: String
        let ink: CGRect
        let fill: CGPoint
        /// 4.5 for text, 3.0 for a glyph.
        let target: Double
    }

    private static let text = 4.5
    private static let glyph = 3.0

    private var appState: AppState { AppStateRuntimeRegistry.shared.appState }

    private func tool(
        _ id: String = "step-tool-1",
        status: ToolActivity.Status = .complete,
        duration: TimeInterval? = 12,
        timestamp: String = "1:20 PM"
    ) -> ChatMessage {
        var message = ChatMessage(id: id, role: .tool, content: "", timestamp: timestamp)
        message.tool = ToolActivity(id: id, name: "web_search",
                                    input: #"{"query":"dinner downtown Asheville"}"#,
                                    output: nil, status: status, duration: duration)
        return message
    }

    private func thinking(duration: TimeInterval? = 12) -> ChatMessage {
        var message = ChatMessage(id: "step-think-1", role: .reasoning, content: "Weighing the options",
                                  timestamp: "1:20 PM")
        message.stepDuration = duration
        return message
    }

    /// Hosts a row as the chat does (R31). The disclosure holds which rows the reader opened.
    private func host<V: View>(_ row: V, disclosure: ChatRowDisclosure) -> some View {
        row
            .chatRows()
            .environment(\.chatRowDisclosure, disclosure)
            .environmentObject(appState)
    }

    /// Renders `content` in light and dark and checks each element. `cardReaches` is a point that
    /// only an opened row covers with its card: a row that did not open would leave the page there.
    private func verify<V: View>(
        _ id: String, height: CGFloat, cardReaches: CGPoint? = nil, elements: [Element],
        @ViewBuilder content: () -> V
    ) throws {
        let view = content()
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let rep = try bitmap(view, size: CGSize(width: Self.width, height: height), dark: dark)
            shoot(rep, "step-\(id)-\(suffix)")
            if let point = cardReaches {
                let card = try fill(rep, at: point)
                let page = try fill(rep, at: CGPoint(x: 210, y: height - 2))
                XCTAssertGreaterThan(abs(card.redComponent - page.redComponent), 0.015,
                                     "\(id) \(suffix): the row did not open (the card stops above y \(point.y))")
            }
            for element in elements {
                check(measure(rep, pointsWide: Self.width, ink: element.ink, fill: element.fill),
                      "\(id) \(element.name) \(suffix)", target: element.target)
            }
        }
    }

    // MARK: Tool row

    // The rectangles are in points, read from the 4x PNGs (`TEST_RUNNER_CONTRAST_SHOTS_DIR`) of the
    // layout on macOS: title at x 51 (14 inset + 26 icon + 11 gap), the time after the title's end,
    // the subject line under the title, the chevron at the trailing edge. Each rectangle holds one
    // element only, so a neighbouring element cannot give a false pass.

    func testToolRowClosed() throws {
        let message = tool()
        try verify("tool-closed", height: 60, elements: [
            Element(name: "title", ink: CGRect(x: 51, y: 12, width: 110, height: 14), fill: CGPoint(x: 300, y: 20), target: Self.text),
            Element(name: "subject", ink: CGRect(x: 51, y: 28, width: 142, height: 13), fill: CGPoint(x: 300, y: 35), target: Self.text),
            Element(name: "duration", ink: CGRect(x: 166, y: 12, width: 20, height: 12), fill: CGPoint(x: 300, y: 20), target: Self.text),
            Element(name: "chevron", ink: CGRect(x: 393, y: 21, width: 14, height: 10), fill: CGPoint(x: 330, y: 28), target: Self.glyph),
        ]) {
            host(ToolCard(message: message), disclosure: ChatRowDisclosure())
        }
    }

    func testToolRowClosedWithClockTime() throws {
        let message = tool(duration: nil)
        try verify("tool-clock", height: 60, elements: [
            Element(name: "clock time", ink: CGRect(x: 166, y: 12, width: 43, height: 12), fill: CGPoint(x: 300, y: 20), target: Self.text),
        ]) {
            host(ToolCard(message: message), disclosure: ChatRowDisclosure())
        }
    }

    func testToolRowRunning() throws {
        let message = tool(status: .running, duration: nil)
        try verify("tool-running", height: 60, elements: [
            Element(name: "running title", ink: CGRect(x: 51, y: 12, width: 113, height: 15), fill: CGPoint(x: 300, y: 20), target: Self.text),
        ]) {
            host(ToolCard(message: message), disclosure: ChatRowDisclosure())
        }
    }

    func testToolRowOpen() throws {
        let message = tool()
        let disclosure = ChatRowDisclosure()
        disclosure.willToggle(message.id, to: true)
        try verify("tool-open", height: 160, elements: [
            Element(name: "title", ink: CGRect(x: 51, y: 17, width: 110, height: 14), fill: CGPoint(x: 300, y: 25), target: Self.text),
            Element(name: "duration", ink: CGRect(x: 166, y: 17, width: 20, height: 12), fill: CGPoint(x: 300, y: 25), target: Self.text),
            Element(name: "chevron", ink: CGRect(x: 393, y: 19, width: 14, height: 9), fill: CGPoint(x: 330, y: 24), target: Self.glyph),
            Element(name: "tool name", ink: CGRect(x: 61, y: 56, width: 64, height: 12), fill: CGPoint(x: 360, y: 60), target: Self.text),
            Element(name: "Input label", ink: CGRect(x: 61, y: 77, width: 28, height: 12), fill: CGPoint(x: 360, y: 83), target: Self.text),
        ]) {
            host(ToolCard(message: message), disclosure: disclosure)
        }
    }

    // MARK: Thinking row

    func testThinkingRowClosed() throws {
        let message = thinking()
        try verify("thinking-closed", height: 60, elements: [
            Element(name: "title", ink: CGRect(x: 51, y: 17, width: 52, height: 15), fill: CGPoint(x: 300, y: 23), target: Self.text),
            Element(name: "duration", ink: CGRect(x: 109, y: 17, width: 19, height: 11), fill: CGPoint(x: 300, y: 23), target: Self.text),
            Element(name: "chevron", ink: CGRect(x: 393, y: 19, width: 14, height: 9), fill: CGPoint(x: 330, y: 23), target: Self.glyph),
        ]) {
            host(ThinkingCard(message: message), disclosure: ChatRowDisclosure())
        }
    }

    func testThinkingRowClosedWithClockTime() throws {
        let message = thinking(duration: nil)
        try verify("thinking-clock", height: 60, elements: [
            Element(name: "clock time", ink: CGRect(x: 109, y: 17, width: 42, height: 11), fill: CGPoint(x: 300, y: 23), target: Self.text),
        ]) {
            host(ThinkingCard(message: message), disclosure: ChatRowDisclosure())
        }
    }

    func testThinkingRowOpen() throws {
        let message = thinking()
        let disclosure = ChatRowDisclosure()
        disclosure.willToggle(message.id, to: true)
        try verify("thinking-open", height: 100, cardReaches: CGPoint(x: 30, y: 60), elements: [
            Element(name: "title", ink: CGRect(x: 51, y: 17, width: 52, height: 15), fill: CGPoint(x: 300, y: 23), target: Self.text),
            Element(name: "duration", ink: CGRect(x: 109, y: 17, width: 19, height: 11), fill: CGPoint(x: 300, y: 23), target: Self.text),
            Element(name: "chevron", ink: CGRect(x: 393, y: 19, width: 14, height: 9), fill: CGPoint(x: 330, y: 23), target: Self.glyph),
        ]) {
            host(ThinkingCard(message: message), disclosure: disclosure)
        }
    }

    // MARK: Run of steps

    /// A turn's run of two tool steps: 7 s and 5 s, 12 s from the first start to the last end.
    private func run() -> (messages: [ChatMessage], group: ChatStepGroup) {
        let first = tool("step-run-1", duration: 7, timestamp: "2026-10-21T13:20:00Z")
        var second = tool("step-run-2", duration: 5, timestamp: "2026-10-21T13:20:07Z")
        second.tool?.name = "read_file"
        let group = ChatStepGroup(members: [ChatStepGroupMember(first), ChatStepGroupMember(second)], isTrailing: false)
        return ([first, second], group)
    }

    func testRunHeaderClosed() throws {
        let (messages, group) = run()
        try verify("run-closed", height: 60, elements: [
            Element(name: "header title", ink: CGRect(x: 73, y: 15, width: 69, height: 14), fill: CGPoint(x: 300, y: 21), target: Self.text),
            Element(name: "header chevron", ink: CGRect(x: 393, y: 17, width: 14, height: 9), fill: CGPoint(x: 330, y: 21), target: Self.glyph),
        ]) {
            host(ChatStepRow(message: messages[0], placement: ChatStepPlacement(group: group, index: 0)),
                 disclosure: ChatRowDisclosure())
        }
    }

    func testRunHeaderAndRowOpen() throws {
        let (messages, group) = run()
        let disclosure = ChatRowDisclosure()
        disclosure.willToggleGroup(group.id, to: true)
        try verify("run-open", height: 100, elements: [
            Element(name: "header title", ink: CGRect(x: 14, y: 11, width: 72, height: 13), fill: CGPoint(x: 300, y: 18), target: Self.text),
            Element(name: "header chevron", ink: CGRect(x: 393, y: 13, width: 14, height: 9), fill: CGPoint(x: 330, y: 18), target: Self.glyph),
            Element(name: "row title", ink: CGRect(x: 51, y: 46, width: 110, height: 14), fill: CGPoint(x: 300, y: 52), target: Self.text),
            Element(name: "row duration", ink: CGRect(x: 165, y: 46, width: 15, height: 12), fill: CGPoint(x: 300, y: 52), target: Self.text),
            Element(name: "row subject", ink: CGRect(x: 51, y: 62, width: 142, height: 12), fill: CGPoint(x: 300, y: 68), target: Self.text),
            Element(name: "row chevron", ink: CGRect(x: 393, y: 55, width: 14, height: 9), fill: CGPoint(x: 330, y: 60), target: Self.glyph),
        ]) {
            host(ChatStepRow(message: messages[0], placement: ChatStepPlacement(group: group, index: 0)),
                 disclosure: disclosure)
        }
    }

    // MARK: Text drawn by an NSTextView

    // Raw input and output and the open thinking text are `SelectableTextView`s, which `ImageRenderer`
    // paints as a placeholder. So these two tests take the colour the rows ask for (`MacStepRowInk`),
    // resolve it under each appearance, composite it over the surface sampled from the render, and
    // apply the same luminance ratio.

    func testRawToolTextHasAtLeast4_5ToOneContrastOnTheOpenBox() throws {
        let message = tool()
        let disclosure = ChatRowDisclosure()
        disclosure.willToggle(message.id, to: true)
        for dark in [false, true] {
            let rep = try bitmap(host(ToolCard(message: message), disclosure: disclosure),
                                 size: CGSize(width: Self.width, height: 160), dark: dark)
            let box = try fill(rep, at: CGPoint(x: 360, y: 60))
            assertInk(MacStepRowInk.nativeText, over: box, dark: dark, name: "raw input and output text")
        }
    }

    func testOpenThinkingTextHasAtLeast4_5ToOneContrastOnTheCard() throws {
        let message = thinking()
        let disclosure = ChatRowDisclosure()
        disclosure.willToggle(message.id, to: true)
        for dark in [false, true] {
            let rep = try bitmap(host(ThinkingCard(message: message), disclosure: disclosure),
                                 size: CGSize(width: Self.width, height: 100), dark: dark)
            let card = try fill(rep, at: CGPoint(x: 300, y: 23))
            assertInk(MacStepRowInk.nativeText, over: card, dark: dark, name: "open thinking text")
        }
    }

    /// The two rows take that colour from `MacStepRowInk`; a source pin, since the colour is not
    /// readable from the view.
    func testNativeTextRowsTakeTheirColourFromMacStepRowInk() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Conduit/Views/ChatView.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "MacStepRowInk.nativeText").count - 1, 2,
                       "the thinking row and the raw text section must both use MacStepRowInk.nativeText")
        XCTAssertEqual(source.components(separatedBy: "textColor: textColor").count - 1, 2,
                       "both SelectableTextViews must take the row's textColor")
    }

    private func fill(_ rep: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / Self.width
        return try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    private func assertInk(_ ink: NSColor, over fill: NSColor, dark: Bool, name: String) {
        let ratio = Self.contrast(ink, over: fill, dark: dark)
        record(Measurement(ratio: ratio, differingPixels: 0, fillIsUniform: true, fillIsNeutral: true),
               "\(name) \(dark ? "dark" : "light")", target: Self.text)
        XCTAssertGreaterThanOrEqual(ratio, Self.text,
                                    "\(name) \(dark ? "dark" : "light"): contrast \(String(format: "%.2f", ratio)):1, need \(Self.text):1")
    }

    /// Contrast of `color`, resolved under the appearance and composited over `fill`, against `fill`.
    private static func contrast(_ color: NSColor, over fill: NSColor, dark: Bool) -> Double {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let a = Double(resolved.alphaComponent)
        func mix(_ t: CGFloat, _ f: CGFloat) -> Double { Double(t) * a + Double(f) * (1 - a) }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
        let text = lum(mix(resolved.redComponent, fill.redComponent),
                       mix(resolved.greenComponent, fill.greenComponent),
                       mix(resolved.blueComponent, fill.blueComponent))
        let back = lum(Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent))
        return (max(text, back) + 0.05) / (min(text, back) + 0.05)
    }
}
