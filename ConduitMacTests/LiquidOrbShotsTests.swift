import XCTest
import AppKit
import MetalKit
@testable import ConduitMac

/// Renders the Metal orb offscreen at a few speech levels for each state and
/// writes PNGs, to eyeball that it draws and changes with the level. Off by
/// default; run with `TEST_RUNNER_CONDUIT_ORB_SHOTS=1`. Output goes to
/// `/private/tmp/conduit-orb-shots/`; delete it afterwards.
@MainActor
final class LiquidOrbShotsTests: XCTestCase {
    private static let directory = "/private/tmp/conduit-orb-shots"
    private static let levels: [Float] = [0, 0.3, 0.7, 1]
    private static let states: [(String, LiquidOrbState)] = [("idle", .idle), ("listening", .listening), ("speaking", .speaking)]
    private static let side = 360

    private struct Frame {
        var width: Int
        var height: Int
        /// BGRA, premultiplied.
        var bytes: [UInt8]
    }

    /// One frame of the orb at `speech`, read back from the drawable.
    private func render(pipeline: LiquidOrbPipeline, state: LiquidOrbState, speech: Float) throws -> Frame {
        let view = LiquidOrbMTKView(frame: .zero, device: pipeline.device)
        view.framebufferOnly = false // readable, for the test only
        view.setFrameSize(NSSize(width: Self.side / 2, height: Self.side / 2))
        view.drawableSize = CGSize(width: Self.side, height: Self.side)
        view.wantsAnimation = false
        let renderer = LiquidOrbRenderer(pipeline: pipeline, state: state, animates: true)
        renderer.speechIsMeasured = true
        renderer.update(state: state, speech: speech, animates: true)
        view.delegate = renderer
        // The renderer eases toward the target and advances its motion by wall
        // time: a few frames apart bring every shot to the same settled look.
        var frame: Frame?
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.12)
            guard let drawable = view.currentDrawable else { throw XCTSkip("no drawable offscreen") }
            view.draw()
            let wait = try XCTUnwrap(pipeline.commandQueue.makeCommandBuffer())
            wait.commit()
            wait.waitUntilCompleted()
            let texture = drawable.texture
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            frame = Frame(width: texture.width, height: texture.height, bytes: bytes)
        }
        return try XCTUnwrap(frame)
    }

    /// The frame over a dark backdrop (the call screen's), as an image.
    private func image(_ frame: Frame) -> CGImage? {
        var composite = frame.bytes
        let background: [Float] = [0.07, 0.06, 0.05] // B, G, R of the call screen's near-black
        for pixel in stride(from: 0, to: composite.count, by: 4) {
            let alpha = Float(frame.bytes[pixel + 3]) / 255
            for channel in 0..<3 {
                let value = Float(frame.bytes[pixel + channel]) / 255 + background[channel] * (1 - alpha)
                composite[pixel + channel] = UInt8(max(0, min(1, value)) * 255)
            }
            composite[pixel + 3] = 255
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return composite.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                      bytesPerRow: frame.width * 4, space: space, bitmapInfo: info)?.makeImage()
        }
    }

    private func write(_ image: CGImage, name: String) throws {
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.directory)/\(name).png"))
    }

    /// Mean absolute difference per channel, 0...255.
    private func difference(_ a: Frame, _ b: Frame) -> Double {
        var total = 0
        for index in 0..<min(a.bytes.count, b.bytes.count) { total += abs(Int(a.bytes[index]) - Int(b.bytes[index])) }
        return Double(total) / Double(a.bytes.count)
    }

    func testOrbRendersAndChangesWithTheLevel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CONDUIT_ORB_SHOTS"] == "1",
                          "set TEST_RUNNER_CONDUIT_ORB_SHOTS=1 to write PNGs")
        let pipeline = try XCTUnwrap(LiquidOrbPipeline.shared)
        try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)

        // A contact sheet: a row per state, a column per level.
        let tile = Self.side
        let sheetWidth = tile * Self.levels.count, sheetHeight = tile * Self.states.count
        var sheet = [UInt8](repeating: 255, count: sheetWidth * sheetHeight * 4)
        for (row, (stateName, state)) in Self.states.enumerated() {
            var frames: [Frame] = []
            for (column, level) in Self.levels.enumerated() {
                let frame = try render(pipeline: pipeline, state: state, speech: level)
                frames.append(frame)
                let picture = try XCTUnwrap(image(frame))
                try write(picture, name: "\(stateName)-\(Int(level * 100))")
                // Not blank: some pixels are drawn.
                let coverage = stride(from: 3, to: frame.bytes.count, by: 4).filter { frame.bytes[$0] > 8 }.count
                XCTAssertGreaterThan(coverage, frame.width * frame.height / 20, "\(stateName) at \(level) is blank")
                // Into the sheet.
                let flat = try XCTUnwrap(image(frame))
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                var pixels = [UInt8](repeating: 0, count: tile * tile * 4)
                pixels.withUnsafeMutableBytes { raw in
                    CGContext(data: raw.baseAddress, width: tile, height: tile, bitsPerComponent: 8, bytesPerRow: tile * 4, space: space, bitmapInfo: info)?
                        .draw(flat, in: CGRect(x: 0, y: 0, width: tile, height: tile))
                }
                for y in 0..<tile {
                    let from = y * tile * 4
                    let to = ((row * tile + y) * sheetWidth + column * tile) * 4
                    sheet.replaceSubrange(to..<(to + tile * 4), with: pixels[from..<(from + tile * 4)])
                }
            }
            // It changes with the level.
            XCTAssertGreaterThan(difference(frames[0], frames[3]), 0.5, "\(stateName): level 0 and 1 look the same")
            XCTAssertGreaterThan(difference(frames[0], frames[2]), 0.3, "\(stateName): level 0 and 0.7 look the same")
            XCTAssertGreaterThan(difference(frames[1], frames[3]), 0.2, "\(stateName): level 0.3 and 1 look the same")
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let contact = sheet.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                      bytesPerRow: sheetWidth * 4, space: space, bitmapInfo: info)?.makeImage()
        }
        try write(try XCTUnwrap(contact), name: "contact-sheet")
    }
}
