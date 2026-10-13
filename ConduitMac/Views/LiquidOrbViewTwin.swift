import SwiftUI

/// Static placeholder; Plan 3 replaces it with the MTKView-backed shader orb.
struct LiquidOrbView: View {
    let pipeline: LiquidOrbPipeline
    var state: LiquidOrbState
    /// 0...1: how strongly the orb swells as if speaking.
    var speech: Float = 0
    var animates = true
    var framesPerSecond = 30

    var body: some View {
        Circle()
            .fill(.tint.opacity(0.35 + Double(speech) * 0.5))
            .animation(.easeOut(duration: 0.1), value: speech)
    }
}
