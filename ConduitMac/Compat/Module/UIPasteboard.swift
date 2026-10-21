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

    /// UIPasteboard.setItems(_:options:): the first item's plain text. With `.expirationDate` the item
    /// is a credential: it also declares the ConcealedType and TransientType markers, so clipboard
    /// managers do not store it, and the board is cleared at the date or when the app quits, but only
    /// if nothing else was copied meanwhile. The deadline is not kept across launches.
    /// `terminationCenter` is a seam for tests; the app uses the default center.
    public func setItems(
        _ items: [[String: Any]],
        options: [OptionsKey: Any] = [:],
        terminationCenter: NotificationCenter = .default
    ) {
        let expiry = options[.expirationDate] as? Date
        let text = items.first?.values.first(where: { $0 is String }) as? String
        var types: [NSPasteboard.PasteboardType] = []
        if text != nil { types.append(.string) }
        if expiry != nil { types += [Self.concealedType, Self.transientType] }
        board.clearContents()
        board.declareTypes(types, owner: nil)
        if let text { board.setString(text, forType: .string) }
        if expiry != nil {
            board.setData(Data(), forType: Self.concealedType)
            board.setData(Data(), forType: Self.transientType)
        }
        guard let expiry else { return }
        let pending = PendingClear(board: board, changeCount: board.changeCount)
        pending.observer = terminationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak pending] _ in pending?.run(center: terminationCenter) }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSinceNow)) {
            pending.run(center: terminationCenter)
        }
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// One pending clear: runs once, from the timer or from quitting, and only for its own copy.
    private final class PendingClear: @unchecked Sendable {
        let board: NSPasteboard
        let changeCount: Int
        var observer: NSObjectProtocol?
        private var done = false

        init(board: NSPasteboard, changeCount: Int) {
            self.board = board
            self.changeCount = changeCount
        }

        func run(center: NotificationCenter) {
            guard !done else { return }
            done = true
            if let observer { center.removeObserver(observer) }
            if board.changeCount == changeCount { board.clearContents() }
        }
    }

    public var hasStrings: Bool { board.canReadObject(forClasses: [NSString.self], options: nil) }
    public var hasImages: Bool { NSImage.canInit(with: board) }
}
