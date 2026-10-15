import SwiftUI

/// Every `Form` the shared iOS views declare is the grouped style on Mac
/// (System Settings cards, header above, footer below). A Mac `Form` with no
/// style is the two-column `.columns` style: section headers float unboxed
/// in the value column and run into the previous footer, and rows are not
/// cards.
///
/// This type shadows `SwiftUI.Form` in the app module (like the other files
/// in Compat/App), so no upstream view changes. `.formStyle(.grouped)` set
/// once at the app root would be the smaller fix, but it does not reach a
/// `.sheet`, nor a sheet opened from a sheet: verified on macOS 27 (D14,
/// `MacFormStyleTests`).
struct Form<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        SwiftUI.Form { content }
            .formStyle(.grouped)
    }

    /// An explicit `.formStyle(...)` on a shared Form wins over the default
    /// grouped style (the inner style is the closest to `SwiftUI.Form`, so an
    /// outer `View.formStyle` alone would lose).
    func formStyle<S: FormStyle>(_ style: S) -> some View {
        SwiftUI.Form { content }
            .formStyle(style)
    }
}
