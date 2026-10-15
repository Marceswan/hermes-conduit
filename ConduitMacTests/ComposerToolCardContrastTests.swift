import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Light- and dark-mode contrast of two controls, measured from rendered
/// pixels:
/// - the composer's reasoning picker ("Medium" and its chevrons) at 4.5:1
///   against the picker's own fill;
/// - the chevron on a settled tool-call card at 3:1 against the card fill.
///
/// Rendered with `ImageRenderer` at the app's root tint (`.conduitAccent`),
/// which is what makes the picker's label render pale gold on Mac. Hosted
/// windows do not paint these views in the test process, so the window path
/// used by `MacSessionTabStripTests` cannot be used here.
///
/// Set `TEST_RUNNER_CONTRAST_SHOTS_DIR=<dir>` to also write the PNGs.
@MainActor
final class ComposerToolCardContrastTests: XCTestCase {
    /// Composer layout in points (720 x 140 render). The reasoning picker pill
    /// spans about x 167...282 and y 80...104 with the current layout.
    private let pickerInk = CGRect(x: 182, y: 84, width: 98, height: 16)
    private let pickerFill = CGPoint(x: 173, y: 92)
    /// Tool card in points (420 x 44 render). The chevron is the trailing
    /// glyph; the card fill shows between the timestamp and the chevron.
    private let chevronInk = CGRect(x: 370, y: 12, width: 30, height: 20)
    private let cardFill = CGPoint(x: 330, y: 22)

    /// Renders `view` at 2x into an opaque RGBA bitmap.
    private func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .tint(.conduitAccent)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    private func shoot(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CONTRAST_SHOTS_DIR"],
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// Highest WCAG contrast between any pixel in `ink` (points) and the pixel
    /// at `fill` (points). Both fixtures are rendered at 2x.
    private func contrast(_ rep: NSBitmapImageRep, ink: CGRect, fill: CGPoint) -> Double {
        let scale = 2.0
        func luminance(_ x: Int, _ y: Int) -> Double? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        guard let bg = luminance(Int(fill.x * scale), Int(fill.y * scale)) else { return 0 }
        var best = 1.0
        for x in Int(ink.minX * scale)..<Int(ink.maxX * scale) {
            for y in Int(ink.minY * scale)..<Int(ink.maxY * scale) {
                guard let l = luminance(x, y) else { continue }
                best = max(best, (max(l, bg) + 0.05) / (min(l, bg) + 0.05))
            }
        }
        return best
    }

    // MARK: Composer reasoning picker

    func testReasoningPickerHasAtLeast4_5ToOneContrastInLightAndDark() throws {
        let appState = AppStateRuntimeRegistry.shared.appState
        let previousModel = appState.runtime.model
        let previousEffort = appState.runtime.reasoningEffort
        defer {
            appState.runtime.model = previousModel
            appState.runtime.reasoningEffort = previousEffort
        }
        appState.runtime.model = "Contrast Test Model"
        appState.runtime.reasoningEffort = "medium"

        for dark in [false, true] {
            let rep = try bitmap(
                ComposerBar().environmentObject(appState)
                    .background(dark ? Color(white: 0.12) : Color.white),
                size: CGSize(width: 720, height: 140), dark: dark)
            let name = dark ? "reasoning-dark" : "reasoning-light"
            shoot(rep, name)
            let ratio = contrast(rep, ink: pickerInk, fill: pickerFill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name): reasoning picker \(ratio):1, need 4.5:1")
        }
    }

    // MARK: Tool-call card chevron

    func testToolCardChevronHasAtLeast3ToOneContrastInLightAndDark() throws {
        var message = ChatMessage(id: "contrast-tool-1", role: .assistant, content: "",
                                  timestamp: "1:20 PM")
        message.tool = ToolActivity(id: "contrast-tool-1", name: "read_file", input: nil,
                                    output: nil, status: .complete)

        for dark in [false, true] {
            let rep = try bitmap(
                SettledToolCardContent(message: message, expandToolsByDefault: false,
                                       sizeCategory: .large)
                    .background(dark ? Color(white: 0.12) : Color.white),
                size: CGSize(width: 420, height: 44), dark: dark)
            let name = dark ? "toolcard-dark" : "toolcard-light"
            shoot(rep, name)
            let ratio = contrast(rep, ink: chevronInk, fill: cardFill)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(name): tool card chevron \(ratio):1, need 3:1")
        }
    }
}
