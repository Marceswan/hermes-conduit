import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// Every file opens in Conduit (D34): `MediaPreviewPresenter` (MediaPreviewPresenterMac.swift) sends
// each open here, from the artifact lists, the chat's panel, a file card or picture in a message,
// and a local attachment. No upstream counterpart: upstream presents Quick Look and the share sheet
// from UIKit.

/// A file and how it draws.
struct MacFilePreview: Equatable {
    enum Content: Equatable {
        /// Drawn by `MarkdownText`.
        case markdown(String)
        /// Drawn in the web view of an agent's page, with its sandbox.
        case html(String)
        /// Shown as it is, so nothing in it runs.
        case text(String)
        /// Drawn from the file by Quick Look.
        case quickLook
        /// Must not reach Quick Look and is not text.
        case unavailable
    }

    let name: String
    let file: URL
    /// The staged directory the sheet removes when it closes; nil for a file in place, which may be
    /// the user's own or a cached gateway picture.
    let ownedDirectory: URL?
    let content: Content

    /// Larger text does not draw here: Quick Look takes it, or the sheet says it has no preview.
    /// Above `HTMLPreviewPage.maximumDocumentBytes` (4 MB), the limit for a page in a message on a
    /// phone: here a page has a sheet of its own, and embedded pictures pass 4 MB easily.
    static let maximumTextBytes = 32 * 1024 * 1024

    /// `quickLookAllowed` is false for what upstream's policy keeps from Quick Look's web renderer
    /// (`MediaPreviewPresenter.isPreviewable`, by extension and by MIME type).
    static func content(of file: URL, quickLookAllowed: Bool) -> Content {
        switch file.pathExtension.lowercased() {
        case "md", "markdown":
            if let text = readableText(of: file) { return .markdown(text) }
        // The extensions the host's plugin lists as pages, and SVG, which is active content too.
        case "html", "htm", "xhtml", "svg":
            if let text = readableText(of: file) { return .html(text) }
        default:
            break
        }
        if drawsAsText(extension: file.pathExtension.lowercased()), let text = readableText(of: file) {
            return .text(text)
        }
        if quickLookAllowed { return .quickLook }
        if let text = readableText(of: file) { return .text(text) }
        return .unavailable
    }

    /// Quick Look draws these as a table or as styled text. Measured on macOS 27.2.
    private static let textQuickLookDrawsBetter: Set<String> = ["csv", "rtf"]
    /// Text files whose declared types do not conform to `public.text`. Quick Look shows an icon.
    private static let textOfOtherTypes: Set<String> = ["vcf", "ics", "gpx", "kml"]

    /// Quick Look shows only an icon for some text (YAML did, measured on macOS 27.2), so text draws
    /// here. A type the system does not know may be text too (`Makefile`, a settings file); the file
    /// decides, in `readableText`.
    private static func drawsAsText(extension fileExtension: String) -> Bool {
        if textQuickLookDrawsBetter.contains(fileExtension) { return false }
        if textOfOtherTypes.contains(fileExtension) { return true }
        guard let type = UTType(filenameExtension: fileExtension), type.isDeclared else { return true }
        return type.conforms(to: .text)
    }

    /// Nil when the file is over the limit, is not UTF-8 (any bytes decode as Latin-1, so they would
    /// draw as garbage), has a NUL byte (binary) or holds only white space.
    private static func readableText(of file: URL) -> String? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maximumTextBytes,
              let data = try? Data(contentsOf: file),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8),
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }
}

/// The file's name over its content. The sheet's way out is the X of `SheetCloseButton`, with Esc and
/// a click behind the sheet: the view marks its window as a content sheet, so nothing the file shows
/// can take those away.
struct MacFilePreviewView: View {
    let name: String
    let content: MacFilePreview.Content
    /// The way to the file itself; nil when there is no file on disk.
    var showInFinder: (() -> Void)? = nil
    /// For a page WebKit cannot keep drawing.
    let close: () -> Void
    /// The file Quick Look draws.
    var file: URL? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            drawn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MacFilePreviewSheetMarker())
    }

    private var titleBar: some View {
        ZStack {
            Text(verbatim: name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                // Clear of the two buttons.
                .padding(.horizontal, 52)
                .accessibilityAddTraits(.isHeader)
            if let showInFinder {
                HStack {
                    Button(action: showInFinder) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .conduitGlassControl(cornerRadius: 13)
                    .help(AppLocalization.string("Show in Finder"))
                    .accessibilityLabel(AppLocalization.string("Show in Finder"))
                    Spacer()
                }
                .padding(.leading, 10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.bar)
    }

    @ViewBuilder
    private var drawn: some View {
        switch content {
        case .markdown(let text):
            ScrollView {
                MarkdownText(source: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        case .html(let text):
            // The sandbox of an agent's page in a message: no origin, and the policy in
            // `HTMLPreviewPage` blocks fetch, frames and forms.
            HTMLPreviewWebView(
                html: HTMLPreviewPage.framed(text, theme: HTMLPreviewTheme(light: colorScheme == .light), presentation: .fullScreen),
                interactive: true,
                // WebKit kept ending the page: close rather than stay blank.
                onFailed: close
            )
        case .text(let text):
            MacFilePreviewTextView(text: text)
        case .quickLook:
            if let file {
                MacFilePreviewQuickLookView(url: file)
            }
        case .unavailable:
            ContentUnavailableView("Couldn’t preview file", systemImage: "doc")
        }
    }
}

/// Marks the window that holds the view, a SwiftUI sheet's or `MacFilePreviewSheet`'s.
private struct MacFilePreviewSheetMarker: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SheetCloseButton.markContentSheet(window) }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {}
}

/// Text as it is, selectable and not editable.
private struct MacFilePreviewTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textColor = .labelColor
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

/// Quick Look's view of a file in the sheet. A video or a clip waits for the user.
private struct MacFilePreviewQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = false
        // `dismantleNSView` closes it: the sheet's window stays alive until the sheet ends.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    /// Also stops a clip or a video that is playing.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Where a link in the preview goes: the app's link policy (R11), because a Markdown file's links are
/// gateway-controlled.
struct MacFilePreviewLinks {
    let routeWidgetLaunch: (URL) -> Bool
    let openAppLink: @MainActor (ConduitAppLink) -> Void

    /// Reads `AppState` only when a link is clicked.
    @MainActor
    static var app: MacFilePreviewLinks {
        MacFilePreviewLinks(routeWidgetLaunch: { AppStateRuntimeRegistry.shared.appState.routeWidgetLaunchURL($0) },
                            openAppLink: { AppStateRuntimeRegistry.shared.appState.openAppLink($0) })
    }
}

/// What every scene's root gives its views. A sheet opened from AppKit is a root of its own, so it
/// inherits none of this. Not zoom: sheets are not zoomed (D27).
private struct MacFilePreviewRoot: View {
    let view: MacFilePreviewView
    let links: MacFilePreviewLinks
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        view
            .environment(\.locale, appLanguage.resolvedLocale)
            .macAccentEnvironment()
            .macLinkPolicy(routeWidgetLaunch: links.routeWidgetLaunch, openAppLink: links.openAppLink)
    }
}

/// Opens a preview as a sheet from AppKit: the presenter is a singleton with no view to hang a
/// SwiftUI sheet on, and the click can come from any window, or from a sheet already open.
@MainActor
enum MacFilePreviewSheet {
    static let minSize = NSSize(width: 560, height: 420)
    static let idealSize = NSSize(width: 800, height: 640)

    /// A sheet's window. SwiftUI's sheet window implements `cancelOperation(_:)` as its dismiss;
    /// `SheetCloseButton` and `SheetEscape` close every sheet through it, so this one does too.
    private final class PreviewWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) {
            sheetParent?.endSheet(self)
        }
    }

    /// What the view and the end of the sheet share.
    private final class Session {
        /// The user sent Finder to the file, so its staged copy stays until the next launch's sweep.
        var keepsFile = false
    }

    static func host(key: NSWindow?, main: NSWindow?) -> NSWindow? {
        key ?? main
    }

    /// False when no window can hold the sheet.
    static func present(_ preview: MacFilePreview) -> Bool {
        present(preview, over: host(key: NSApp.keyWindow, main: NSApp.mainWindow))
    }

    @discardableResult
    static func present(_ preview: MacFilePreview, over window: NSWindow?, links: MacFilePreviewLinks? = nil) -> Bool {
        let links = links ?? .app
        guard var parent = window else { return false }
        while let sheet = parent.attachedSheet { parent = sheet }
        let sheet = PreviewWindow(contentRect: NSRect(origin: .zero, size: idealSize),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        // SwiftUI's `preferredColorScheme` sets the look on the app's own windows, not on this one.
        sheet.appearance = parent.effectiveAppearance
        let session = Session()
        let view = MacFilePreviewView(
            name: preview.name,
            content: preview.content,
            showInFinder: {
                if MediaPreviewPresenter.reveal(preview.file, ownedDirectory: nil) { session.keepsFile = true }
            },
            close: { [weak sheet] in sheet?.cancelOperation(nil) },
            file: preview.file)
        let controller = NSHostingController(rootView: MacFilePreviewRoot(view: view, links: links))
        // The window sets the size: the content's ideal size would collapse the web view.
        controller.sizingOptions = []
        sheet.contentViewController = controller
        sheet.contentMinSize = minSize
        sheet.setContentSize(NSSize(width: idealSize.width, height: min(idealSize.height, MacFormSheet.idealHeight)))
        parent.beginSheet(sheet) { _ in
            // Takes the view down now, so a playing clip stops with the sheet.
            sheet.contentViewController = nil
            if !session.keepsFile { MediaPreviewPresenter.removeDirectory(preview.ownedDirectory) }
        }
        return true
    }
}
