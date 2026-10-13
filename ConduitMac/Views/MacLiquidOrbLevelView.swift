import SwiftUI

/// The call orb on Mac: `LiquidOrbView` with the swell driven by the live
/// audio level instead of the phase's 0 or 1 (LiveVoiceOrb builds it).
/// Observing the meter here keeps its ~30 Hz updates to this view alone.
///
/// Until the call's audio source has reported anything (or when it never
/// does), the orb keeps the phase's own swell, so a provider that cannot
/// measure looks as it did before.
struct MacLiquidOrbLevelView: View {
    let pipeline: LiquidOrbPipeline
    let look: LiveVoiceOrb.LiquidLook
    let phase: LiveVoiceCallPhase
    let animates: Bool
    let lowPowerMode: Bool
    @ObservedObject var meter: LiveVoiceLevelMeter

    var body: some View {
        LiquidOrbView(
            pipeline: pipeline,
            state: look.state,
            speech: meter.drivesOrb ? meter.level : look.speech,
            animates: animates,
            framesPerSecond: meter.drivesOrb
                ? LiveVoiceLevelMeter.framesPerSecond(loud: meter.isLoud, lowPowerMode: lowPowerMode)
                : LiveVoiceOrbPower.framesPerSecond(speaking: look.state == .speaking, lowPowerMode: lowPowerMode),
            speechIsMeasured: meter.drivesOrb
        )
        .onAppear { sync() }
        .onChange(of: phase) { _, _ in sync() }
        .onChange(of: animates) { _, _ in sync() }
        .onDisappear { meter.stop() }
    }

    /// A still orb has no use for a level: the meter and any polling stop.
    private func sync() {
        meter.route(phase: phase)
        if animates { meter.start() } else { meter.stop() }
    }
}
