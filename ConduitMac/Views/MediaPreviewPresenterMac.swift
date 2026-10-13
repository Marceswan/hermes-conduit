import AppKit

// Mac side of MediaPreviewPresenter. Upstream presents Quick Look and the
// share sheet from a UIViewController; here both reveal the file in Finder.
// Placeholder: a QLPreviewPanel preview replaces this later.
extension MediaPreviewPresenter {
    struct Session {
        let url: URL
        let title: String
        let ownedDirectory: URL?
    }

    @discardableResult
    func show(_ session: Session) -> Bool {
        reveal(session.url, ownedDirectory: session.ownedDirectory)
    }

    /// The staged copy stays on disk; the next launch's sweep removes it.
    func share(fileURL: URL, ownedDirectory: URL?) -> Bool {
        reveal(fileURL, ownedDirectory: ownedDirectory)
    }

    /// The bytes and name come from the gateway or model, so the file is
    /// quarantined first; if that fails nothing is revealed.
    private func reveal(_ url: URL, ownedDirectory: URL?) -> Bool {
        do {
            try FileQuarantine.markQuarantined(url)
        } catch {
            Self.removeDirectory(ownedDirectory)
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
