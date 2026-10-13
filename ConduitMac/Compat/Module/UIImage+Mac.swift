import AppKit

public extension NSImage {
    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
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
