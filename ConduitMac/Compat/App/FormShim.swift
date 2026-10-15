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
/// `.sheet`, nor a sheet opened from a sheet, on macOS 14 to 27: a sheet's Form
/// is `.columns` whatever the presenter sets (D14, `MacFormStyleTests`).
struct Form<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        SwiftUI.Form { content }
            .formStyle(.grouped)
    }
}
