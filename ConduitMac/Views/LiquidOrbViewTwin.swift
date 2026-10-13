import AppKit
import MetalKit
import QuartzCore
import SwiftUI

/// The Metal orb as a SwiftUI view: the Mac twin of upstream's UIViewRepresentable
/// (LiquidOrbView.swift). Check `LiquidOrbPipeline.shared` first: without Metal
/// there is nothing to draw. Named `...Twin` because two files with one name in
/// one target make Xcode drop one.
struct LiquidOrbView: NSViewRepresentable {
    let pipeline: LiquidOrbPipeline
    var state: LiquidOrbState
    /// 0...1: how strongly the orb swells as if speaking.
    var speech: Float = 0
    var animates = true
    /// See LiveVoiceOrbPower: 60 only while speaking, unless in Low Power Mode.
    var framesPerSecond = 30
    /// `speech` is a measured audio level (LiveVoiceLevelMeter) rather than the
    /// call phase's 0 or 1: the renderer follows it closely instead of easing it.
    var speechIsMeasured = false

    func makeCoordinator() -> LiquidOrbRenderer {
        LiquidOrbRenderer(pipeline: pipeline, state: state, animates: animates)
    }

    func makeNSView(context: Context) -> LiquidOrbMTKView {
        let view = LiquidOrbMTKView(frame: .zero, device: pipeline.device)
        view.delegate = context.coordinator
        configure(view, renderer: context.coordinator)
        return view
    }

    func updateNSView(_ view: LiquidOrbMTKView, context: Context) {
        configure(view, renderer: context.coordinator)
    }

    private func configure(_ view: LiquidOrbMTKView, renderer: LiquidOrbRenderer) {
        renderer.speechIsMeasured = speechIsMeasured
        renderer.update(state: state, speech: speech, animates: animates)
        view.preferredFramesPerSecond = framesPerSecond
        view.wantsAnimation = animates
    }
}

/// The orb's MTKView. It mirrors the iOS view (bgra8Unorm, framebuffer only,
/// clear and non-opaque, no accessibility element) and adds what a window
/// brings: a pixel scale that follows the display the window is on, and no
/// drawing while the window is occluded.
final class LiquidOrbMTKView: MTKView {
    /// The shader is soft-edged: 2x is indistinguishable from 3x here and
    /// shades less than half the pixels, so a Retina display never goes
    /// above 2x (the iOS view's contentScaleFactor = 2). A 1x display stays 1x.
    static let maxPixelScale: CGFloat = 2

    /// Off under Reduce Motion and the like: frames are drawn on demand and hold still.
    var wantsAnimation = true {
        didSet { applyPause() }
    }
    private(set) var isWindowVisible = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The drawable is sized here, from the window's display (below).
        autoResizeDrawable = false
        if let layer = layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.backgroundColor = NSColor.clear.cgColor
            // The look was tuned on iOS, which tags the layer sRGB.
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        setAccessibilityElement(false)
        applyPause()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    self?.occlusionChanged()
                },
                // A move to another display can change the backing scale and the refresh rate.
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.displayChanged()
                },
            ]
        }
        occlusionChanged()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        syncDrawableSize()
    }

    /// The pixel scale this view draws at on its current display.
    var pixelScale: CGFloat {
        min(Self.maxPixelScale, window?.backingScaleFactor ?? Self.maxPixelScale)
    }

    private func displayChanged() {
        syncDrawableSize()
        // Re-applying the rate makes the display link pick up the new display.
        let rate = preferredFramesPerSecond
        preferredFramesPerSecond = rate
    }

    private func syncDrawableSize() {
        let scale = pixelScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        layer?.contentsScale = scale
        if drawableSize != size { drawableSize = size }
    }

    private func occlusionChanged() {
        setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        applyPause()
    }

    /// Animating draws on the display link while the window shows; otherwise
    /// the view is paused, and a still orb draws once per request.
    private func applyPause() {
        enableSetNeedsDisplay = !wantsAnimation
        isPaused = !wantsAnimation || !isWindowVisible
        if !wantsAnimation { setNeedsDisplay(bounds) }
    }
}
