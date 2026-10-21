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

    public struct OptionsKey: Hashable, Sendable {
        let name: String
        public static let expirationDate = OptionsKey(name: "expirationDate")
    }

    /// UIPasteboard.setItems(_:options:): the first item's plain text, cleared after
    /// `.expirationDate` unless something else was copied meanwhile.
    public func setItems(_ items: [[String: Any]], options: [OptionsKey: Any] = [:]) {
        board.clearContents()
        if let text = items.first?.values.first(where: { $0 is String }) as? String {
            board.setString(text, forType: .string)
        }
        guard let expiry = options[.expirationDate] as? Date else { return }
        let board = board
        let count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSinceNow)) {
            if board.changeCount == count { board.clearContents() }
        }
    }

    public var hasStrings: Bool { board.canReadObject(forClasses: [NSString.self], options: nil) }
    public var hasImages: Bool { NSImage.canInit(with: board) }
}
