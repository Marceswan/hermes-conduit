import AppKit
import SwiftUI

public extension NSImage {
    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    /// UIImage.scale: pixels per point of the sharpest representation.
    var scale: CGFloat {
        guard size.width > 0,
              let pixels = representations.map(\.pixelsWide).max(), pixels > 0 else { return 1 }
        return CGFloat(pixels) / size.width
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
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
