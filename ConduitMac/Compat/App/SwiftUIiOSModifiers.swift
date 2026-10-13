import SwiftUI
import UIKit

// No-op stand-ins for iOS-only SwiftUI API that upstream views call. They
// live in the app module so they shadow the SDK's macOS-unavailable
// declarations. Members are added only when the compiler asks for them.

extension View {
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View { self }

    func textInputAutocapitalization(_ style: TextInputAutocapitalization?) -> some View { self }

    func keyboardType(_ type: UIKeyboardType) -> some View { self }

    /// A Mac window has no full-screen cover; a sheet is the closest modal.
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}

/// SwiftUI's NavigationBarItem is unavailable on macOS; this one shadows it.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

struct TextInputAutocapitalization: Sendable {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}
