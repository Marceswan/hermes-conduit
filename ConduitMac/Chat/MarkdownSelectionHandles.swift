import SwiftUI

/// iOS drag handles for cross-block selection. Mac uses native selection.
struct MarkdownSelectionHandleOverlay: View {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator
    var body: some View { EmptyView() }
}

@MainActor
final class MarkdownSelectionChromeLocator: ObservableObject {
    static let shared = MarkdownSelectionChromeLocator()
    private init() {}

    func selectionOwnerDidChange() {
        objectWillChange.send()
    }
}

struct MarkdownSelectionChromeRoot: View {
    var body: some View { EmptyView() }
}
