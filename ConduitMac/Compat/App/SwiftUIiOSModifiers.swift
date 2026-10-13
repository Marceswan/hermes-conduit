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

/// Stand-in for iOS's `ToolbarPlacement.navigationBar`. Mac windows have no iOS navigation bar,
/// and mapping it to `.windowToolbar` made `.toolbar(.hidden, for: .navigationBar)` hide the
/// window's title bar and traffic lights. The overloads below shadow SwiftUI's and do nothing.
struct MacNavigationBarPlacement: Sendable {
    static var navigationBar: MacNavigationBarPlacement { MacNavigationBarPlacement() }
}

extension View {
    func toolbar(_ visibility: Visibility, for bars: MacNavigationBarPlacement) -> some View { self }
    func toolbarBackground(_ visibility: Visibility, for bars: MacNavigationBarPlacement) -> some View { self }
}
