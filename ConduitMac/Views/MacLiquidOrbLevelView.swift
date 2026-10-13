import SwiftUI

/// The call orb on Mac: `LiquidOrbView` with the swell driven by the live
/// audio level instead of the phase's 0 or 1 (LiveVoiceOrb builds it).
/// Observing the meter here keeps its ~30 Hz updates to this view alone.
///
/// Until the call's audio source has reported anything (or when it never
/// does), the orb keeps the phase's own swell, so a provider that cannot
/// measure looks as it did before.
///
/// The meter (its 30 Hz timer, the republishing, and a provider's polling)
/// runs only while the orb animates AND its window shows. Visibility comes
/// from the same signal that pauses the MTKView (window occlusion, minimise,
/// no window); it starts false and the view reports true once it is on screen.
struct MacLiquidOrbLevelView: View {
    let pipeline: LiquidOrbPipeline
    let look: LiveVoiceOrb.LiquidLook
    let phase: LiveVoiceCallPhase
    let animates: Bool
    let lowPowerMode: Bool
    @ObservedObject var meter: LiveVoiceLevelMeter
    @State private var isWindowVisible = false

    var body: some View {
        LiquidOrbView(
            pipeline: pipeline,
            state: look.state,
            speech: meter.drivesOrb ? meter.level : look.speech,
            animates: animates,
            framesPerSecond: meter.drivesOrb
                ? LiveVoiceLevelMeter.framesPerSecond(loud: meter.isLoud, lowPowerMode: lowPowerMode)
                : LiveVoiceOrbPower.framesPerSecond(speaking: look.state == .speaking, lowPowerMode: lowPowerMode),
            speechIsMeasured: meter.drivesOrb,
            onVisibilityChange: { visible in
                // From an AppKit notification, possibly inside a view update.
                DispatchQueue.main.async { isWindowVisible = visible }
            }
        )
        .onAppear { sync() }
        .onChange(of: phase) { _, _ in sync() }
        .onChange(of: animates) { _, _ in sync() }
        .onChange(of: isWindowVisible) { _, _ in sync() }
        .onDisappear { meter.stop() }
    }

    /// A still or hidden orb has no use for a level: the meter and any polling stop.
    private func sync() {
        meter.route(phase: phase)
        if Self.shouldMeter(animates: animates, windowVisible: isWindowVisible) { meter.start() } else { meter.stop() }
    }

    static func shouldMeter(animates: Bool, windowVisible: Bool) -> Bool {
        animates && windowVisible
    }
}
