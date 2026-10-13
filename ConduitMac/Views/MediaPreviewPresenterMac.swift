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
        NSWorkspace.shared.activateFileViewerSelecting([session.url])
        return true
    }

    /// The staged copy stays on disk; the next launch's sweep removes it.
    func share(fileURL: URL, ownedDirectory: URL?) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return true
    }
}
