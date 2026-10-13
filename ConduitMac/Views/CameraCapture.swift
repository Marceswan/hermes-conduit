import SwiftUI
import UIKit

/// Not ported (spec non-goal). `isAvailable == false` hides the camera action.
struct CameraCapture: View {
    static var isAvailable: Bool { false }
    let onCapture: (UIImage) -> Void
    var body: some View { EmptyView() }
}
