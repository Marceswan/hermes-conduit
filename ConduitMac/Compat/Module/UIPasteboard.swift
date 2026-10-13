import AppKit

public final class UIPasteboard {
    public static let general = UIPasteboard(.general)

    public let board: NSPasteboard

    public init(_ board: NSPasteboard) {
        self.board = board
    }

    public var string: String? {
        get { board.string(forType: .string) }
        set {
            board.clearContents()
            if let newValue { board.setString(newValue, forType: .string) }
        }
    }

    public var image: NSImage? {
        get { NSImage(pasteboard: board) }
        set {
            board.clearContents()
            if let newValue { board.writeObjects([newValue]) }
        }
    }

    public var url: URL? {
        get { board.readObjects(forClasses: [NSURL.self])?.first as? URL }
        set {
            board.clearContents()
            if let newValue { board.writeObjects([newValue as NSURL]) }
        }
    }

    public var hasStrings: Bool { board.canReadObject(forClasses: [NSString.self], options: nil) }
    public var hasImages: Bool { NSImage.canInit(with: board) }
}
