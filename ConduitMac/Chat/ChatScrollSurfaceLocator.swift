import SwiftUI

/// Task 6 placeholder: leaves ChatScrollEngine detached, which upstream
/// handles by falling back to ScrollViewProxy. Task 9 attaches NSScrollView.
struct ChatScrollSurfaceLocator: View {
    let engine: ChatScrollEngine
    var body: some View { Color.clear.allowsHitTesting(false) }
}
