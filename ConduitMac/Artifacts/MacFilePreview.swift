import AppKit
import PDFKit
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
        /// Drawn by PDFKit, whose delegate sends links through the app's policy.
        case pdf
        /// RTF in the text view, whose delegate sends links through the app's policy.
        case richText(NSAttributedString)
        /// Drawn from the file by Quick Look. Only the types on its list reach it.
        case quickLook
        /// No drawing for this file: Show in Finder is the way to it.
        case unavailable
    }

    let name: String
    let file: URL
    /// The staged directory the sheet removes when it closes; nil for a file in place, which may be
    /// the user's own or a cached gateway picture.
    let ownedDirectory: URL?
    let content: Content

    /// Larger text says it has no preview. Above `HTMLPreviewPage.maximumDocumentBytes` (4 MB), the
    /// limit for a page in a message on a phone: here a page has a sheet of its own, and embedded
    /// pictures pass 4 MB easily.
    static let maximumTextBytes = 32 * 1024 * 1024

    /// `quickLookAllowed` is false for what upstream's policy keeps from Quick Look's web renderer
    /// (`MediaPreviewPresenter.isPreviewable`, by extension and by MIME type).
    static func content(of file: URL, quickLookAllowed: Bool) -> Content {
        let fileExtension = file.pathExtension.lowercased()
        switch fileExtension {
        case "md", "markdown":
            if let text = readableText(of: file) { return .markdown(text) }
        // The extensions the host's plugin lists as pages, and SVG, which is active content too.
        case "html", "htm", "xhtml", "svg":
            if let text = readableText(of: file) { return .html(text) }
        case "pdf" where quickLookAllowed:
            if PDFDocument(url: file) != nil { return .pdf }
        case "rtf" where quickLookAllowed:
            if let rich = richText(of: file) { return .richText(rich) }
        default:
            break
        }
        if drawsAsText(extension: fileExtension), let text = readableText(of: file) { return .text(text) }
        if quickLookAllowed, quickLookDraws(extension: fileExtension), !startsLikeWebContent(file) { return .quickLook }
        if let text = readableText(of: file) { return .text(text) }
        return .unavailable
    }

    /// Quick Look draws this as a table. Measured on macOS 27.2.
    private static let textQuickLookDrawsBetter: Set<String> = ["csv"]
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

    /// Documents whose declared types are not one of the groups below.
    private static let quickLookDocuments: Set<String> = ["doc", "docx", "pages", "odt", "ods", "csv"]

    /// The list of what reaches Quick Look. Upstream's policy is a list of what must not, and mail
    /// (`.eml`), web locations (`.webloc`, `.url`) and any later type pass it, so on Mac nothing
    /// reaches Quick Look unless it is named here.
    private static func quickLookDraws(extension fileExtension: String) -> Bool {
        if quickLookDocuments.contains(fileExtension) { return true }
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        return [UTType.image, .audiovisualContent, .presentation, .spreadsheet].contains { type.conforms(to: $0) }
    }

    /// A page under a document's name. Quick Look goes by the name, so this should only fail to draw,
    /// but nothing relies on that for a file the host or a model named.
    private static func startsLikeWebContent(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return false }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        return ["<html", "<!doctype html", "<svg", "<script"].contains { text.contains($0) }
    }

    /// Nil when the file is over the limit or is not RTF.
    private static func richText(of file: URL) -> NSAttributedString? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maximumTextBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
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
            MacFilePreviewTextView(source: .plain(text))
        case .richText(let rich):
            MacFilePreviewTextView(source: .rich(rich))
        case .pdf:
            if let file {
                MacFilePreviewPDFView(url: file)
            }
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
struct MacFilePreviewSheetMarker: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SheetCloseButton.markContentSheet(window) }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {}
}

/// Text, selectable and not editable. A link in it passes the app's policy.
private struct MacFilePreviewTextView: NSViewRepresentable {
    enum Source {
        /// Shown as it is.
        case plain(String)
        case rich(NSAttributedString)
    }

    let source: Source

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        context.coordinator.openURL = context.environment.openURL
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.delegate = context.coordinator
            switch source {
            case .plain(let text):
                view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                view.textColor = .labelColor
                view.string = text
            case .rich(let rich):
                view.isRichText = true
                // An RTF file's black text stays readable in dark.
                view.usesAdaptiveColorMappingForDarkAppearance = true
                view.textStorage?.setAttributedString(rich)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?

        /// True in every case, so a link never reaches NSTextView's default NSWorkspace handling.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = SelectableTextView.Coordinator.url(fromLink: link) { openURL?(url) }
            return true
        }
    }
}

/// A PDF in PDFKit, not Quick Look, because a Quick Look link leaves the app's link policy.
private struct MacFilePreviewPDFView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        context.coordinator.openURL = context.environment.openURL
        view.delegate = context.coordinator
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var openURL: OpenURLAction?

        /// In place of PDFKit's default, which opens the link through the system.
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            openURL?(url)
        }

        /// A PDF in the sheet does not open another file.
        func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
    }
}

/// Quick Look's view of a file in the sheet. A video or a clip waits for the user. A link in an office
/// file is Quick Look's own and does not pass the app's policy (D34).
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
private struct MacFilePreviewRoot<Content: View>: View {
    let view: Content
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
        let session = Session()
        let size = NSSize(width: idealSize.width, height: min(idealSize.height, MacFormSheet.idealHeight))
        return begin(over: window, links: links, size: size, ended: {
            if !session.keepsFile { MediaPreviewPresenter.removeDirectory(preview.ownedDirectory) }
        }, content: { close in
            MacFilePreviewView(
                name: preview.name,
                content: preview.content,
                showInFinder: {
                    if MediaPreviewPresenter.reveal(preview.file, ownedDirectory: nil) { session.keepsFile = true }
                },
                close: close,
                file: preview.file)
        })
    }

    /// `content` as a sheet over the top sheet of `window`, with what a scene's root gives its views.
    /// `content` gets the way to close it. `ended` runs when the sheet has gone. False when there is
    /// no window.
    @discardableResult
    static func begin<Content: View>(over window: NSWindow?, links: MacFilePreviewLinks? = nil, size: NSSize,
                                     ended: @escaping @MainActor () -> Void,
                                     content: (_ close: @escaping () -> Void) -> Content) -> Bool {
        let links = links ?? .app
        guard var parent = window else { return false }
        while let sheet = parent.attachedSheet { parent = sheet }
        let sheet = PreviewWindow(contentRect: NSRect(origin: .zero, size: idealSize),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        // SwiftUI's `preferredColorScheme` sets the look on the app's own windows, not on this one.
        sheet.appearance = parent.effectiveAppearance
        let view = content({ [weak sheet] in sheet?.cancelOperation(nil) })
        let controller = NSHostingController(rootView: MacFilePreviewRoot(view: view, links: links))
        // The window sets the size: the content's ideal size would collapse the web view.
        controller.sizingOptions = []
        sheet.contentViewController = controller
        sheet.contentMinSize = minSize
        sheet.setContentSize(size)
        parent.beginSheet(sheet) { _ in
            // Takes the view down now, so a playing clip stops with the sheet.
            sheet.contentViewController = nil
            ended()
        }
        return true
    }
}
