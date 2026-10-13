import SwiftUI

/// Native NSTextView selection draws its own highlight on Mac.
struct MarkdownSelectionHighlightOverlay: View {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator
    var body: some View { EmptyView() }
}
