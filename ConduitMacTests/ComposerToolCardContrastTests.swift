import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// Light- and dark-mode contrast of the composer reasoning picker and the
/// tool-call card (name, time, chevron), measured from rendered pixels.
///
/// Rendered with `ImageRenderer` at 4x and the app's root tint
/// (`.conduitAccent`), which is what makes the picker label render pale gold
/// on Mac. Hosted windows do not paint these views in the test process.
///
/// Each measurement checks that the fill sample is a uniform neutral surface
/// (not white, not the accent) and that the ink rect holds enough pixels that
/// differ from the fill, so a layout shift cannot pass vacuously.
///
/// Set `TEST_RUNNER_CONTRAST_SHOTS_DIR=<dir>` to also write the PNGs.
@MainActor
final class ComposerToolCardContrastTests: XCTestCase {
    private static let renderScale: CGFloat = 4

    /// Composer layout in points (720 x 140 render, 4x). With the system menu
    /// indicator hidden the reasoning pill spans about x 167...259 and
    /// y 66...118. "Medium" sits at x 184...231 and the chevrons at x 236...243.
    private let pickerInk = CGRect(x: 182, y: 84, width: 68, height: 16)
    private let pickerFill = CGPoint(x: 173, y: 92)
    /// Tool card in points (420 x 44 render). Name, time and chevron are read
    /// from the 2x layout; the card fill shows between the time and chevron.
    private let nameInk = CGRect(x: 45, y: 14, width: 60, height: 16)
    private let timeInk = CGRect(x: 108, y: 14, width: 48, height: 16)
    private let chevronInk = CGRect(x: 378, y: 12, width: 22, height: 20)
    private let cardFill = CGPoint(x: 330, y: 22)

    /// Renders `view` at 4x into an opaque bitmap with the app tint.
    private func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .tint(.conduitAccent)
            .environment(\.colorScheme, dark ? .dark : .light))
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

    /// Contrast of the highest-contrast pixel in `ink` (points) against the
    /// fill at `fill` (points), plus sanity checks on the fill itself.
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

        // Fill: a 5x5 block must be one colour, and must be neutral (not yellow
        // accent, not a stray tint).
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

    private func check(_ m: Measurement, _ name: String, target: Double) {
        XCTAssertTrue(m.fillIsUniform, "\(name): fill sample is not a uniform surface")
        XCTAssertTrue(m.fillIsNeutral, "\(name): fill sample is not a neutral surface")
        XCTAssertGreaterThanOrEqual(m.differingPixels, 10, "\(name): too few ink pixels differ from the fill")
        XCTAssertGreaterThanOrEqual(m.ratio, target, "\(name): contrast \(String(format: "%.2f", m.ratio)):1, need \(target):1")
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
            let m = measure(rep, pointsWide: 720, ink: pickerInk, fill: pickerFill)
            check(m, name, target: 4.5)
        }
    }

    // MARK: Tool-call card

    func testToolCardNameTimeAndChevronMeetContrastInLightAndDark() throws {
        var message = ChatMessage(id: "contrast-tool-1", role: .assistant, content: "",
                                  timestamp: "1:20 PM")
        message.tool = ToolActivity(id: "contrast-tool-1", name: "read_file", input: nil,
                                    output: nil, status: .complete)
        let appState = AppStateRuntimeRegistry.shared.appState
        // The settled card only renders when tool progress is shown. The
        // default preference is on, and AppState exposes no setter for tests.
        XCTAssertTrue(appState.displayPreferences.showToolProgress,
                      "tool progress must be shown for the settled card to render")

        for dark in [false, true] {
            let rep = try bitmap(
                ToolCard(message: message)
                    .environmentObject(appState)
                    .background(dark ? Color(white: 0.12) : Color.white),
                size: CGSize(width: 420, height: 44), dark: dark)
            let suffix = dark ? "dark" : "light"
            shoot(rep, "toolcard-\(suffix)")
            check(measure(rep, pointsWide: 420, ink: nameInk, fill: cardFill), "tool name \(suffix)", target: 4.5)
            check(measure(rep, pointsWide: 420, ink: timeInk, fill: cardFill), "tool time \(suffix)", target: 4.5)
            check(measure(rep, pointsWide: 420, ink: chevronInk, fill: cardFill), "tool chevron \(suffix)", target: 3.0)
        }
    }
}
