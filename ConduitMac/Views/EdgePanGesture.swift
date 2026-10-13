import SwiftUI

/// The iPhone left-edge swipe has no Mac meaning; the sidebar is a column.
struct EdgePanGesture: View {
    var action: () -> Void
    var body: some View { EmptyView() }
}
