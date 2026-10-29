import AppKit
import SwiftUI

public extension NSImage {
    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    /// UIImage.scale: pixels per point of the sharpest representation. A bitmap reports its own pixels. An image
    /// built from a `CGImage` has a snapshot representation whose `pixelsWide` follows the screen's scale (2 for a
    /// 1x image on a Retina Mac), so those use the pixels of the `CGImage`.
    var scale: CGFloat {
        guard size.width > 0 else { return 1 }
        let bitmapPixels = representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }.max()
        guard let pixels = bitmapPixels ?? cgImage?.width ?? representations.map(\.pixelsWide).max(), pixels > 0 else { return 1 }
        return CGFloat(pixels) / size.width
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// UIImage.draw(at:): the image at its natural size, origin at `point`.
    func draw(at point: CGPoint) {
        draw(in: CGRect(origin: point, size: size))
    }

    func pngData() -> Data? {
        bitmapRepresentation?.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmapRepresentation?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    private var bitmapRepresentation: NSBitmapImageRep? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}

public extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}
