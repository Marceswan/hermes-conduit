import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop attachments for the Mac chat pane. Files, folders and raw
// images dropped anywhere on the pane reach the composer through the same
// entry points as the paperclip picker and image paste, so size limits,
// type handling and per-chat draft isolation are the composer's own.

/// What a drag carries that the composer can attach.
enum MacAttachmentDropPayload: Equatable {
    case fileURLs([URL])
    case images([PastedImage])
}

enum MacAttachmentDropPolicy {
    /// Shown when a drop had more files than a message can carry.
    static var tooManyMessage: String {
        AppLocalization.string("Too many files to attach at once. Only the first ones were added.")
    }

    /// Cheap type check for hover feedback: never reads file contents.
    static func hasAttachableContent(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

    /// File URLs win over image data: a Finder drag of a photo also carries
    /// a bitmap, and the file goes through the picker's staging.
    static func payload(from pasteboard: NSPasteboard) -> MacAttachmentDropPayload? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return .fileURLs(urls)
        }
        let images = ComposerTextView.pastedImages(from: pasteboard)
        return images.isEmpty ? nil : .images(images)
    }

    struct Expansion: Equatable {
        /// What to attach, in drop order, folders replaced by their files.
        var urls: [URL]
        /// Files left out because the message is full.
        var overflow: Int
        /// Names of dropped packages (.app, .rtfd, ...). A package is a folder
        /// on disk but one item to the user: it is neither expanded nor staged
        /// (copying it would pull its whole tree in with no size check, and
        /// the result cannot be uploaded as a file).
        var packages: [String] = []
    }

    /// Folders become their top-level regular files (hidden files, symlinks,
    /// subfolders and nested packages skipped, no recursion), name order.
    /// Dropped packages are set aside, not expanded. Everything is then
    /// trimmed to the slots left under `cap`.
    static func expand(
        _ urls: [URL],
        existingCount: Int,
        cap: Int,
        fileManager: FileManager = .default
    ) -> Expansion {
        var files: [URL] = []
        var packages: [String] = []
        for url in urls {
            if isPackage(url) {
                packages.append(url.lastPathComponent)
            } else if isDirectory(url) {
                files.append(contentsOf: topLevelFiles(of: url, fileManager: fileManager))
            } else {
                files.append(url)
            }
        }
        let slots = max(0, cap - existingCount)
        return Expansion(
            urls: Array(files.prefix(slots)),
            overflow: max(0, files.count - slots),
            packages: packages
        )
    }

    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func topLevelFiles(of folder: URL, fileManager: FileManager) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

enum MacAttachmentDropRouter {
    /// Hands a payload to the composer's existing attach paths. Files are
    /// delivered as one list, exactly what the document picker produces;
    /// raw images one by one, like a paste. Anything over the cap is
    /// dropped and reported once through `overflow`; dropped packages are
    /// refused and named once through `packages`.
    static func route(
        _ payload: MacAttachmentDropPayload,
        existingCount: Int,
        cap: Int,
        attachFiles: ([URL]) -> Void,
        attachImage: (PastedImage) -> Void,
        overflow: (Int) -> Void,
        packages: ([String]) -> Void = { _ in }
    ) {
        switch payload {
        case .fileURLs(let urls):
            let expansion = MacAttachmentDropPolicy.expand(urls, existingCount: existingCount, cap: cap)
            if !expansion.urls.isEmpty { attachFiles(expansion.urls) }
            if expansion.overflow > 0 { overflow(expansion.overflow) }
            if !expansion.packages.isEmpty { packages(expansion.packages) }
        case .images(let images):
            let slots = max(0, cap - existingCount)
            images.prefix(slots).forEach(attachImage)
            if images.count > slots { overflow(images.count - slots) }
        }
    }
}

/// The composer's side of a drop: whether it takes drops right now, and what
/// to do with one.
struct MacAttachmentDropReceiver {
    var isEnabled: () -> Bool
    var receive: (MacAttachmentDropPayload) -> Void
}

/// Meeting point between the pane-level drop target, the composer's text
/// view (which AppKit hands drags to first) and the composer itself.
@MainActor
final class MacAttachmentDropSink: ObservableObject {
    /// A drag that would be accepted is over the pane; drives the overlay.
    @Published private(set) var isTargeted = false
    var receiver: MacAttachmentDropReceiver?

    /// AppKit calls this on every drag update; `@Published` announces a
    /// change even for an equal value, so only real changes are published.
    func setTargeted(_ targeted: Bool) {
        if isTargeted != targeted { isTargeted = targeted }
    }

    /// `.copy` when the drag carries attachable content and the composer is
    /// unlocked; empty (no-drop cursor) otherwise.
    func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        guard let receiver, receiver.isEnabled(),
              MacAttachmentDropPolicy.hasAttachableContent(pasteboard) else { return [] }
        return .copy
    }

    func perform(_ pasteboard: NSPasteboard) -> Bool {
        setTargeted(false)
        guard !operation(for: pasteboard).isEmpty,
              let receiver,
              let payload = MacAttachmentDropPolicy.payload(from: pasteboard) else { return false }
        receiver.receive(payload)
        return true
    }
}

private struct MacAttachmentDropSinkKey: EnvironmentKey {
    static let defaultValue: MacAttachmentDropSink? = nil
}

extension EnvironmentValues {
    var macAttachmentDropSink: MacAttachmentDropSink? {
        get { self[MacAttachmentDropSinkKey.self] }
        set { self[MacAttachmentDropSinkKey.self] = newValue }
    }
}

// MARK: - Pane-level drop target

@MainActor
private struct MacAttachmentDropDelegate: DropDelegate {
    let sink: MacAttachmentDropSink

    private var pasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    func validateDrop(info: DropInfo) -> Bool {
        MacAttachmentDropPolicy.hasAttachableContent(pasteboard)
    }

    func dropEntered(info: DropInfo) {
        sink.setTargeted(!sink.operation(for: pasteboard).isEmpty)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = !sink.operation(for: pasteboard).isEmpty
        sink.setTargeted(allowed)
        return DropProposal(operation: allowed ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        sink.setTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        sink.perform(pasteboard)
    }
}

private struct MacChatAttachmentDropModifier: ViewModifier {
    @StateObject private var sink = MacAttachmentDropSink()

    func body(content: Content) -> some View {
        content
            .environment(\.macAttachmentDropSink, sink)
            .onDrop(of: [.fileURL, .image], delegate: MacAttachmentDropDelegate(sink: sink))
            .overlay {
                if sink.isTargeted { MacAttachmentDropOverlay() }
            }
    }
}

private struct MacAttachmentDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay {
                Text(AppLocalization.string("Drop to attach"))
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// Registers the composer as the receiver of the enclosing pane's drops.
private struct MacAttachmentDropReceiverModifier: ViewModifier {
    @Environment(\.macAttachmentDropSink) private var sink
    let receiver: MacAttachmentDropReceiver

    func body(content: Content) -> some View {
        content
            .onAppear { sink?.receiver = receiver }
            .onDisappear { sink?.receiver = nil }
    }
}

extension View {
    /// Make the whole pane a drop target for files, folders and images.
    func macChatAttachmentDrop() -> some View {
        modifier(MacChatAttachmentDropModifier())
    }

    /// Mark this view as the composer that takes the pane's drops.
    func macAttachmentDropReceiver(
        isEnabled: @escaping () -> Bool,
        receive: @escaping (MacAttachmentDropPayload) -> Void
    ) -> some View {
        modifier(MacAttachmentDropReceiverModifier(
            receiver: MacAttachmentDropReceiver(isEnabled: isEnabled, receive: receive)
        ))
    }
}
