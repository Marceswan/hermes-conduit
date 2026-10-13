import AppKit

public final class UIGraphicsImageRendererFormat {
    public var scale: CGFloat
    public var opaque = false
    public init() { scale = NSScreen.main?.backingScaleFactor ?? 2 }
}

public final class UIGraphicsImageRendererContext {
    public let cgContext: CGContext
    init(cgContext: CGContext) { self.cgContext = cgContext }
}

/// Offscreen bitmap rendering. The origin is bottom-left (AppKit's), unlike
/// UIKit's top-left: that keeps `NSImage.draw(in:)`, the only drawing upstream
/// does here, right side up. Raw `cgContext` drawing would be mirrored.
public final class UIGraphicsImageRenderer {
    private let size: CGSize
    private let format: UIGraphicsImageRendererFormat

    public init(size: CGSize, format: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()) {
        self.size = size
        self.format = format
    }

    public func image(actions: (UIGraphicsImageRendererContext) -> Void) -> NSImage {
        let pixelsWide = max(1, Int((size.width * format.scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * format.scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        actions(UIGraphicsImageRendererContext(cgContext: graphics.cgContext))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
