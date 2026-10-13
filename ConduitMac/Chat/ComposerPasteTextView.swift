import AppKit
import SwiftUI

struct PastedImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

/// Mac twin of upstream ComposerPasteTextView. Placeholder: Task 8 replaces
/// the body with an NSTextView-backed representable (paste, Return handling).
struct ComposerPasteTextView: View {
    static var minimumHeight: CGFloat { max(36, ceil(bodyLineHeight) + 16) }
    static var maximumHeight: CGFloat { min(max(160, ceil(bodyLineHeight) * 4 + 16), 280) }
    private static var bodyLineHeight: CGFloat { NSFont.preferredFont(forTextStyle: .body).lineHeight }

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

    var body: some View {
        TextEditor(text: $text)
            .disabled(!enabled)
            .onChange(of: text) { _, _ in onUserEdit?() }
    }
}
