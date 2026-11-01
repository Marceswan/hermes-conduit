import AppKit

// Mac side of MediaPreviewPresenter. Upstream presents Quick Look and the share sheet from a
// UIViewController. Here both land in `open`, which draws the file in a sheet inside Conduit (D34,
// MacFilePreview.swift).
// `present(downloaded:)` (the Artifacts list and Markdown file cards, upstream #569) is upstream's
// shared body, not duplicated here: the file is already on disk, it calls `show` for a previewable
// file and `share` for a page type Quick Look must not render.
// Finder is the last resort, for when no window can hold the sheet.
extension MediaPreviewPresenter {
    struct Session {
        let url: URL
        let title: String
        let ownedDirectory: URL?
    }

    @discardableResult
    func show(_ session: Session) -> Bool {
        open(session.url, title: session.title, ownedDirectory: session.ownedDirectory, quickLookAllowed: true)
    }

    func share(fileURL: URL, ownedDirectory: URL?) -> Bool {
        open(fileURL, title: fileURL.lastPathComponent, ownedDirectory: ownedDirectory, quickLookAllowed: false)
    }

    /// How a file is shown in Finder. A seam for tests, which must not open Finder.
    static var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// How a preview is shown; false when no window can hold it. A seam for tests.
    static var presentPreview: (MacFilePreview) -> Bool = { MacFilePreviewSheet.present($0) }

    /// Every file is quarantined first, as `reveal` does: a file in place may be the user's own or a
    /// cached gateway picture, and the path does not tell which. The owned directory says only what
    /// the sheet removes. A staged copy that cannot be marked opens nothing; a file in place that
    /// cannot be marked still draws, because only the sheet reads it, and Show in Finder refuses it.
    /// `share` is what upstream's policy keeps from Quick Look, so it comes here with
    /// `quickLookAllowed` false.
    private func open(_ url: URL, title: String, ownedDirectory: URL?, quickLookAllowed: Bool) -> Bool {
        do {
            try FileQuarantine.markQuarantined(url)
        } catch {
            if ownedDirectory != nil {
                Self.removeDirectory(ownedDirectory)
                return false
            }
        }
        let preview = MacFilePreview(name: title, file: url, ownedDirectory: ownedDirectory,
                                     content: MacFilePreview.content(of: url, quickLookAllowed: quickLookAllowed))
        guard Self.presentPreview(preview) else { return Self.reveal(url, ownedDirectory: ownedDirectory) }
        // As upstream's Quick Look: the rows stay on screen, so their `onDisappear` does not stop an
        // inline clip, and the sheet has its own player.
        ChatAudioClipPlayer.shared.stop()
        return true
    }

    /// The bytes and name come from the gateway or model, so the file is
    /// quarantined first; if that fails nothing is revealed.
    @discardableResult
    static func reveal(_ url: URL, ownedDirectory: URL?) -> Bool {
        do {
            try FileQuarantine.markQuarantined(url)
        } catch {
            removeDirectory(ownedDirectory)
            return false
        }
        revealInFinder(url)
        return true
    }
}
