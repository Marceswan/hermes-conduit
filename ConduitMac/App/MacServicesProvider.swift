import AppKit

/// The object behind `NSApp.servicesProvider`. Info.plist `NSServices[0].NSMessage`
/// names `sendToHermes`; AppKit calls `sendToHermes:userData:error:` (D19).
final class MacServicesProvider: NSObject {
    static let selectorName = "sendToHermes"

    private let sink: @MainActor (String) -> Void

    init(sink: @escaping @MainActor (String) -> Void) {
        self.sink = sink
    }

    @objc func sendToHermes(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // `string(forType: .string)` converts rich text to plain text.
        guard let text = MacServiceText.normalize(pboard.string(forType: .string)) else {
            error.pointee = AppLocalization.string("No text selected") as NSString
            return
        }
        // Services calls arrive on the main thread; hop explicitly rather than assume.
        let sink = self.sink
        Task { @MainActor in sink(text) }
    }
}
