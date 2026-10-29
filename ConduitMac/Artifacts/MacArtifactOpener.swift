import SwiftUI

// Open for an artifact list: the Artifacts pane and sheet (D26) and the chat's side panel (D33).
// Moved out of `MacArtifactsList` unchanged, so both lists open a file the same way. No upstream
// counterpart (upstream keeps this as `@State` inside the private `ArtifactsList`).

/// One list's open in flight and what it presents: a page in a sheet, or an alert for a file that
/// is gone or too large. Hang `macArtifactOpenPresentation` on the list that owns it.
@MainActor
final class MacArtifactOpener: ObservableObject {
    struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    /// The item being opened; one open at a time.
    @Published private(set) var openingID: String?
    @Published var page: OpenPage?
    @Published var missing: ArtifactItem?
    /// The alert is for a file too big to download, not a gone one.
    @Published private(set) var missingIsTooLarge = false
    /// Cancelled when the list goes, so a slow fetch can't present a viewer over whatever the
    /// user moved on to.
    private var openTask: Task<Void, Never>?

    static func action(for item: ArtifactItem) -> MacArtifactOpen? {
        if let url = item.url, item.path == nil { return .link(url) }
        guard let path = item.path else { return nil }
        guard item.exists else { return .missing }
        return item.kind == .page ? .page(path: path) : .file(path: path)
    }

    /// Cancels the open in flight (the list went, or the server changed).
    func cancel() {
        openTask?.cancel()
        openingID = nil
    }

    func open(_ item: ArtifactItem, source: MacArtifactsSource, appState: AppState, openURL: OpenURLAction) {
        guard let action = Self.action(for: item) else { return }
        if case .link(let url) = action {
            openURL(url)
            return
        }
        guard openingID == nil else { return }
        let reader = source.reader(appState)
        switch action {
        case .link:
            break   // opened above
        case .missing:
            missingIsTooLarge = false
            missing = item
        case .page(let path):
            openingID = item.id
            openTask = Task { @MainActor in
                defer { openingID = nil }
                if let dataURL = await reader.dataURL(path), !Task.isCancelled,
                   let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) {
                    page = OpenPage(name: item.name, html: html)
                    return
                }
                // Not drawable in the sheet (no data URL, over the size limit, not UTF-8): open it
                // like any other file, which also says why when it cannot.
                guard !Task.isCancelled else { return }
                await openFile(item, path: path, reader: reader, source: source)
            }
        case .file(let path):
            openingID = item.id
            openTask = Task { @MainActor in
                defer { openingID = nil }
                await openFile(item, path: path, reader: reader, source: source)
            }
        }
    }

    /// Downloads the file and shows it (quarantined, in Finder), else shows it from its data URL.
    private func openFile(_ item: ArtifactItem, path: String, reader: MacArtifactsReader,
                          source: MacArtifactsSource) async {
        switch await reader.file(path) {
        case .downloaded(let download):
            guard !Task.isCancelled else {
                MediaPreviewPresenter.removeDirectory(download.directory)
                return
            }
            if source.present(download) { return }
        case .tooLarge:
            openFailed(item, tooLarge: true)
            return
        case .unavailable:
            break
        }
        // A cancelled download reads as unavailable; no fallback for a list that has gone.
        guard !Task.isCancelled else { return }
        guard let dataURL = await reader.dataURL(path) else {
            openFailed(item)
            return
        }
        guard !Task.isCancelled else { return }
        guard await source.presentDataURL(dataURL, item.name) else {
            openFailed(item)
            return
        }
    }

    private func openFailed(_ item: ArtifactItem, tooLarge: Bool = false) {
        guard !Task.isCancelled else { return }
        missingIsTooLarge = tooLarge
        missing = item
    }
}

private struct MacArtifactOpenPresentation: ViewModifier {
    @ObservedObject var opener: MacArtifactOpener

    func body(content: Content) -> some View {
        content
            .sheet(item: $opener.page) { page in
                HTMLPreviewSheet(name: page.name, html: page.html)
                    .macFormSheetSize(minWidth: 560, idealWidth: 800, minHeight: 420, idealHeight: 640)
            }
            .onDisappear { opener.cancel() }
            .alert(
                opener.missingIsTooLarge ? Text("Too large to open on this Mac") : Text("This file is no longer on your Hermes host."),
                isPresented: Binding(get: { opener.missing != nil }, set: { if !$0 { opener.missing = nil } })
            ) {
                Button("OK", role: .cancel) { opener.missing = nil }
            } message: {
                Text(verbatim: opener.missing?.path ?? "")
            }
    }
}

extension View {
    /// The page sheet and the missing-file alert of `opener`'s list. Cancels its open when the
    /// list goes.
    func macArtifactOpenPresentation(_ opener: MacArtifactOpener) -> some View {
        modifier(MacArtifactOpenPresentation(opener: opener))
    }
}
