import AppKit

// Mac side of MediaPreviewPresenter. Upstream presents Quick Look and the
// share sheet from a UIViewController; here both reveal the file in Finder.
// `present(downloaded:)` (the Artifacts list and Markdown file cards, upstream #569) is upstream's
// shared body, not duplicated here: the file is already on disk, it calls `show` for a previewable
// file and `share` for a page type Quick Look must not render, and on Mac both land in `reveal`.
// So a downloaded file is quarantined and revealed in Finder; a page is never rendered.
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

    /// How a staged file is shown. A seam for tests, which must not open Finder.
    static var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// The bytes and name come from the gateway or model, so the file is
    /// quarantined first; if that fails nothing is revealed.
    private func reveal(_ url: URL, ownedDirectory: URL?) -> Bool {
        do {
            try FileQuarantine.markQuarantined(url)
        } catch {
            Self.removeDirectory(ownedDirectory)
            return false
        }
        Self.revealInFinder(url)
        return true
    }
}
