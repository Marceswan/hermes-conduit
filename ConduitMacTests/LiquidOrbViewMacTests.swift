import XCTest
import AppKit
import MetalKit
import SwiftUI
@testable import ConduitMac

/// The Mac orb: the Metal library built into the app finds the shader's
/// functions, the MTKView mirrors the iOS configuration, and it stops
/// drawing when it should.
@MainActor
final class LiquidOrbViewMacTests: XCTestCase {
    private func requirePipeline() throws -> LiquidOrbPipeline {
        try XCTUnwrap(LiquidOrbPipeline.shared, "Metal pipeline unavailable: LiquidOrb.metal missing from the Mac target's default library?")
    }

    func testDefaultLibraryHoldsTheOrbFunctions() throws {
        let pipeline = try requirePipeline()
        let library = try XCTUnwrap(pipeline.device.makeDefaultLibrary())
        XCTAssertNotNil(library.makeFunction(name: "vs_main"))
        XCTAssertNotNil(library.makeFunction(name: "fs_main"))
        XCTAssertEqual(pipeline.state.device.registryID, pipeline.device.registryID)
    }

    func testViewMirrorsTheIOSConfiguration() throws {
        let pipeline = try requirePipeline()
        let view = LiquidOrbMTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), device: pipeline.device)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertTrue(view.framebufferOnly)
        XCTAssertFalse(view.isOpaque)
        XCTAssertEqual(view.clearColor.alpha, 0)
        XCTAssertFalse(view.isAccessibilityElement())
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertFalse(layer.isOpaque)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
    }

    func testPixelScaleIsCappedAtTwoAndDrawableFollowsBounds() throws {
        let pipeline = try requirePipeline()
        let view = LiquidOrbMTKView(frame: .zero, device: pipeline.device)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.setFrameSize(NSSize(width: 150, height: 120))
        let scale = min(2, window.backingScaleFactor)
        XCTAssertEqual(view.pixelScale, scale)
        XCTAssertEqual(view.drawableSize, CGSize(width: 150 * scale, height: 120 * scale))
        XCTAssertEqual(view.layer?.contentsScale, scale)
        window.contentView = nil
        window.close()
    }

    func testPausesWhenOccludedOrStill() throws {
        let pipeline = try requirePipeline()
        let view = LiquidOrbMTKView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), device: pipeline.device)
        view.wantsAnimation = true
        view.setWindowVisible(true)
        XCTAssertFalse(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)
        // Occluded: the display link stops, nothing draws on demand.
        view.setWindowVisible(false)
        XCTAssertTrue(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)
        view.setWindowVisible(true)
        XCTAssertFalse(view.isPaused)
        // Reduce Motion and the like: on demand only.
        view.wantsAnimation = false
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
    }

    func testRepresentableConfiguresViewAndFrameRate() throws {
        let pipeline = try requirePipeline()
        let model = OrbHostModel()
        let window = HostedTestSupport.host(
            OrbHost(pipeline: pipeline, model: model).frame(width: 160, height: 160),
            size: NSSize(width: 160, height: 160))
        defer { HostedTestSupport.tearDown(window) }
        func orbView() -> LiquidOrbMTKView? { Self.find(LiquidOrbMTKView.self, in: window.contentView) }
        XCTAssertTrue(HostedTestSupport.waitUntil { orbView() != nil })
        let view = try XCTUnwrap(orbView())
        XCTAssertEqual(view.preferredFramesPerSecond, 30)
        XCTAssertNotNil(view.delegate as? LiquidOrbRenderer)
        model.framesPerSecond = 60
        XCTAssertTrue(HostedTestSupport.waitUntil { view.preferredFramesPerSecond == 60 })
        model.animates = false
        XCTAssertTrue(HostedTestSupport.waitUntil { view.isPaused && view.enableSetNeedsDisplay })
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}

@MainActor
private final class OrbHostModel: ObservableObject {
    @Published var framesPerSecond = 30
    @Published var animates = true
}

private struct OrbHost: View {
    let pipeline: LiquidOrbPipeline
    @ObservedObject var model: OrbHostModel

    var body: some View {
        LiquidOrbView(pipeline: pipeline, state: .listening, speech: 0, animates: model.animates, framesPerSecond: model.framesPerSecond)
    }
}
