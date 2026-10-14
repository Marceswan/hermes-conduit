import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PastedImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

/// Mac twin of upstream ComposerPasteTextView: NSTextView-backed composer with
/// image paste/drop routing and Return-to-submit that respects IME composition.
struct ComposerPasteTextView: NSViewRepresentable {
    static var minimumHeight: CGFloat { max(44, ceil(bodyLineHeight) + 16) }
    static var maximumHeight: CGFloat { min(max(160, ceil(bodyLineHeight) * 4 + 16), 280) }
    private static var bodyLineHeight: CGFloat { NSFont.preferredFont(forTextStyle: .body).lineHeight }

    @AppStorage(MacSidebarState.tabDefaultsKey) private var routeTabRaw = SidebarTab.sessions.rawValue
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (PastedImage) -> Void
    let onPastedImageError: (String) -> Void
    let editorIdentity: UUID
    var programmaticRevision: UInt64 = 0
    var programmaticCursorAtEnd = false
    var returnKeySends: Bool = false
    var canSubmitFromReturn: Bool = false
    var onSubmitFromReturn: (() -> Bool)? = nil
    var onUserEdit: (() -> Void)? = nil
    /// Where Cmd-L arrives (`macFocusComposerRequested`); injectable for tests.
    var focusRequestCenter: NotificationCenter = .default

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        context.coordinator.lastRevision = programmaticRevision
        configure(textView)
        context.coordinator.observeFocusRequests(for: textView, center: focusRequestCenter)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        configure(textView)
        // Only an intentional programmatic replacement rewrites the editor.
        if programmaticRevision != context.coordinator.lastRevision {
            context.coordinator.lastRevision = programmaticRevision
            if textView.string != text, !textView.hasMarkedText() {
                textView.string = text
                if programmaticCursorAtEnd {
                    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                }
            }
        }
        // A chat hidden under Bots / Cron / Kanban must not take or keep focus.
        // Focus lost to the route is held (isFocused stays true) and restored
        // on return, unless something else owns the keyboard by then.
        if isFocused && MacChatRoute.isChatActive(tabRaw: routeTabRaw) {
            if let window = textView.window {
                textView.wantsFocus = false
                if textView.heldFocusForRoute {
                    textView.restoreFocusIfHeld()
                } else if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            } else {
                // Not in a window yet; ComposerTextView.viewDidMoveToWindow applies this.
                textView.wantsFocus = true
            }
        } else {
            textView.wantsFocus = false
            if textView.window?.firstResponder === textView {
                if MacChatRoute.isChatActive(tabRaw: routeTabRaw) {
                    textView.window?.makeFirstResponder(nil)
                } else {
                    textView.resignForRoute()
                }
            }
        }
        context.coordinator.remeasure(textView)
    }

    private func configure(_ textView: ComposerTextView) {
        textView.isEditable = enabled
        textView.returnKeySends = returnKeySends
        textView.canSubmitFromReturn = canSubmitFromReturn
        textView.onSubmitFromReturn = onSubmitFromReturn
        textView.onPastedImages = { images in images.forEach(onPastedImage) }
        let focus = $isFocused
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { focus.wrappedValue = focused }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerPasteTextView
        var lastRevision: UInt64 = 0
        private var focusObserver: NSObjectProtocol?
        private var focusObserverCenter: NotificationCenter?

        init(_ parent: ComposerPasteTextView) { self.parent = parent }

        deinit {
            if let focusObserver { focusObserverCenter?.removeObserver(focusObserver) }
        }

        /// Cmd-L: the composer in the command's window takes first responder.
        func observeFocusRequests(for textView: ComposerTextView, center: NotificationCenter) {
            focusObserverCenter = center
            focusObserver = center.addObserver(forName: .macFocusComposerRequested, object: nil, queue: .main) { [weak textView] note in
                guard let textView, let window = textView.window else { return }
                if let target = note.object as? NSWindow, target !== window { return }
                textView.focusFromCommand()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onUserEdit?()
            remeasure(textView)
        }

        func remeasure(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            let clamped = min(max(content, ComposerPasteTextView.minimumHeight), ComposerPasteTextView.maximumHeight)
            if abs(parent.measuredHeight - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.measuredHeight = clamped }
            }
        }
    }
}

enum PasteDecision: Equatable {
    case images([PastedImage])
    case text
}

final class ComposerTextView: NSTextView {
    var returnKeySends = false
    var canSubmitFromReturn = false
    var onSubmitFromReturn: (() -> Bool)?
    var onPastedImages: (([PastedImage]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Focus requested before the view had a window; honoured in viewDidMoveToWindow.
    var wantsFocus = false

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    }

    // NSTextView's init(frame:) forwards here, so both must be overridden.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted && !resigningForRoute { onFocusChange?(false) }
        return accepted
    }

    /// The route hid the chat while this composer had focus. Not reported as a
    /// focus loss, so the owner's isFocused stays true and the return to chat
    /// can restore it.
    var heldFocusForRoute = false
    private var resigningForRoute = false

    func resignForRoute() {
        guard let window, window.firstResponder === self else { return }
        resigningForRoute = true
        heldFocusForRoute = window.makeFirstResponder(nil)
        resigningForRoute = false
    }

    /// Focus is restored only when no sheet is attached and no other text
    /// input (sidebar search, a pane field editor) owns the keyboard. When it
    /// is not restored the owner is told focus is gone, so a later update
    /// does not steal it.
    @discardableResult
    func restoreFocusIfHeld() -> Bool {
        guard heldFocusForRoute else { return false }
        heldFocusForRoute = false
        guard let window else { return false }
        if window.firstResponder === self { return true }
        if window.attachedSheet == nil, !(window.firstResponder is NSText), window.makeFirstResponder(self) {
            return true
        }
        onFocusChange?(false)
        return false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

    /// Image file URLs (Finder copies). Checked before the string so filenames do not win.
    static func imageFileImages(from pasteboard: NSPasteboard) -> [PastedImage] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return urls.compactMap { url -> PastedImage? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let data = try? Data(contentsOf: url) else { return nil }
            return PastedImage(data: data, typeIdentifier: type.identifier)
        }
    }

    static func pastedImages(from pasteboard: NSPasteboard) -> [PastedImage] {
        let fileImages = imageFileImages(from: pasteboard)
        if !fileImages.isEmpty { return fileImages }
        if let data = pasteboard.data(forType: .png) {
            return [PastedImage(data: data, typeIdentifier: UTType.png.identifier)]
        }
        if let data = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            return [PastedImage(data: png, typeIdentifier: UTType.png.identifier)]
        }
        return []
    }

    /// True when Return was consumed as a submit.
    func handleReturn(shift: Bool) -> Bool {
        guard !shift, !hasMarkedText(), returnKeySends, canSubmitFromReturn else { return false }
        return onSubmitFromReturn?() ?? false
    }

    /// Shift-Return and Option-Return (the Mac chat convention) insert a new line.
    static func isNewlineModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.shift, .option]).isEmpty
    }

    /// Cmd-L. Refused while a sheet is attached or the composer is read-only;
    /// an explicit request replaces any focus the route was holding.
    @discardableResult
    func focusFromCommand() -> Bool {
        guard let window, isEditable, !isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return false }
        heldFocusForRoute = false
        return window.firstResponder === self || window.makeFirstResponder(self)
    }

    /// Tab and Shift-Tab leave the composer along the window's key view loop
    /// (sidebar list, search field, composer), as in a single-line field.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, handleReturn(shift: Self.isNewlineModifier(event.modifierFlags)) { return }
        super.keyDown(with: event)
    }

    /// Text wins over bitmap previews (Excel, Word, Safari copies carry both).
    /// Image file URLs still attach as images.
    static func pasteDecision(for pasteboard: NSPasteboard) -> PasteDecision {
        let fileImages = imageFileImages(from: pasteboard)
        if !fileImages.isEmpty { return .images(fileImages) }
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return .text }
        let images = pastedImages(from: pasteboard)
        return images.isEmpty ? .text : .images(images)
    }

    /// `.copy` when the pasteboard carries an image; empty to defer to NSTextView.
    func dragOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
        Self.pastedImages(from: pasteboard).isEmpty ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dragOperation(for: sender.draggingPasteboard)
        return operation.isEmpty ? super.draggingEntered(sender) : operation
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !dragOperation(for: sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        switch Self.pasteDecision(for: .general) {
        case .images(let images):
            onPastedImages?(images)
        case .text:
            pasteAsPlainText(sender)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = Self.pastedImages(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onPastedImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }
}
