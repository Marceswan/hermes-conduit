import XCTest
import os
@testable import ConduitMac

// Synthetic PCM16 helpers: a sine of the given peak amplitude (full scale = 1).
private func sinePCM16(amplitude: Float, frames: Int, sampleRate: Double = 24_000, frequency: Double = 440) -> Data {
    var data = Data(capacity: frames * 2)
    for index in 0..<frames {
        let value = Double(amplitude) * sin(2 * .pi * frequency * Double(index) / sampleRate)
        var sample = Int16(max(-32768, min(32767, (value * 32768).rounded()))).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

private func silencePCM16(frames: Int) -> Data { Data(count: frames * 2) }

final class LiveVoiceLevelScaleTests: XCTestCase {
    func testRMSOfASineIsPeakOverRootTwo() {
        let rms = LiveVoiceLevelScale.rms(pcm16: sinePCM16(amplitude: 0.5, frames: 24_000))
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot().asFloat, accuracy: 0.002)
    }

    func testRMSOfSilenceEmptyAndOddLengthData() {
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: silencePCM16(frames: 480)), 0)
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: Data()), 0)
        // A trailing odd byte is ignored, not read past the end.
        var odd = sinePCM16(amplitude: 0.5, frames: 100)
        odd.append(0x7F)
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: odd), LiveVoiceLevelScale.rms(pcm16: sinePCM16(amplitude: 0.5, frames: 100)), accuracy: 1e-6)
    }

    func testRMSOfAWindowAndFullScaleSquare() {
        // 100 frames of +full scale, then 100 of silence.
        var data = Data()
        for _ in 0..<100 { var s = Int16.min.littleEndian; withUnsafeBytes(of: &s) { data.append(contentsOf: $0) } }
        data.append(silencePCM16(frames: 100))
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: data, from: 0, frames: 100), 1, accuracy: 1e-6)
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: data, from: 100, frames: 100), 0)
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: data, from: 50, frames: 100), (0.5 as Float).squareRoot(), accuracy: 1e-5)
        // Past the end: nothing to measure.
        XCTAssertEqual(LiveVoiceLevelScale.rms(pcm16: data, from: 500, frames: 100), 0)
    }

    func testDecibelMapping() {
        func rms(db: Float) -> Float { pow(10, db / 20) }
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: rms(db: -50)), 0, accuracy: 1e-5)
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: rms(db: -10)), 1, accuracy: 1e-5)
        // Clamped either side.
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: rms(db: -80)), 0)
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: 1), 1)
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: 0), 0)
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: .nan), 0)
        // Midpoint (-30 dB) is half the span before the curve.
        XCTAssertEqual(LiveVoiceLevelScale.level(rms: rms(db: -30)), pow(0.5, LiveVoiceLevelScale.curveExponent), accuracy: 1e-4)
    }

    func testCurveIsMonotonicAndGentle() {
        var last: Float = -1
        for db in stride(from: Float(-60), through: 0, by: 1) {
            let level = LiveVoiceLevelScale.level(rms: pow(10, db / 20))
            XCTAssertGreaterThanOrEqual(level, last)
            last = level
        }
        // Quiet below linear: more swing between soft and loud syllables.
        XCTAssertLessThan(LiveVoiceLevelScale.level(rms: pow(10, -30 / 20)), 0.5)
    }
}

private extension Double { var asFloat: Float { Float(self) } }

final class LiveVoiceLevelRoutingTests: XCTestCase {
    func testSourceByPhase() {
        typealias Route = LiveVoiceLevelRouting
        XCTAssertEqual(Route.source(phase: .speaking), .assistant)
        XCTAssertEqual(Route.source(phase: .listening), .microphone)
        XCTAssertEqual(Route.source(phase: .muted), .assistant)
        for phase in [LiveVoiceCallPhase.idle, .connecting, .ending, .failed] {
            XCTAssertEqual(Route.source(phase: phase), .none, "\(phase)")
        }
    }

    func testMutedNeverRoutesTheMicrophone() {
        for phase in [LiveVoiceCallPhase.idle, .connecting, .listening, .speaking, .muted, .ending, .failed] {
            XCTAssertNotEqual(LiveVoiceLevelRouting.source(phase: phase, isMicrophoneMuted: true), .microphone, "\(phase)")
        }
        XCTAssertEqual(LiveVoiceLevelRouting.source(phase: .listening, isMicrophoneMuted: true), .assistant)
    }
}

final class LiveVoiceLevelFeedTests: XCTestCase {
    func testInputIsNilUntilReportedThenStale() {
        let feed = LiveVoiceLevelFeed()
        XCTAssertNil(feed.inputRMS(at: 10))
        feed.pushInput(rms: 0.2, at: 10)
        XCTAssertEqual(feed.inputRMS(at: 10.1), 0.2)
        XCTAssertEqual(feed.inputRMS(at: 10.5), 0, "a level that stopped arriving is silence")
    }

    func testOutputWindowsFollowPlaybackTime() throws {
        let feed = LiveVoiceLevelFeed()
        XCTAssertNil(feed.outputRMS(at: 0))
        // 0.2 s loud then 0.2 s silent, 24 kHz, queued at t = 100.
        feed.pushOutput(pcm16: sinePCM16(amplitude: 0.5, frames: 4_800) + silencePCM16(frames: 4_800), sampleRate: 24_000, at: 100)
        let loud = try XCTUnwrap(feed.outputRMS(at: 100.1))
        XCTAssertEqual(loud, 0.354, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 100.3)), 0, accuracy: 1e-6)
        // After the audio has played out, a gap is silence.
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 101)), 0)
    }

    func testSecondChunkQueuesBehindTheFirst() throws {
        let feed = LiveVoiceLevelFeed()
        feed.pushOutput(pcm16: silencePCM16(frames: 24_000), sampleRate: 24_000, at: 0) // 1 s of silence
        feed.pushOutput(pcm16: sinePCM16(amplitude: 0.5, frames: 2_400), sampleRate: 24_000, at: 0.1) // arrives early
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 0.5)), 0, accuracy: 1e-6, "not audible yet")
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 1.05)), 0.354, accuracy: 0.01)
    }

    func testClearAndResetOutput() throws {
        let feed = LiveVoiceLevelFeed()
        feed.pushOutput(pcm16: sinePCM16(amplitude: 0.5, frames: 24_000), sampleRate: 24_000, at: 0)
        feed.clearOutput()
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 0.2)), 0, "an interrupt silences what was queued")
        feed.resetOutput()
        XCTAssertNil(feed.outputRMS(at: 0.2))
    }

    func testInstantOutputHoldsBrieflyThenGoesStale() throws {
        let feed = LiveVoiceLevelFeed()
        feed.pushOutput(rms: 0.1, at: 50)
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 50.1)), 0.1)
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS(at: 50.6)), 0)
    }

    func testWatchObserversHearTransitionsOnly() {
        let feed = LiveVoiceLevelFeed()
        let log = OSAllocatedUnfairLock(initialState: [Bool]())
        let id = feed.observeWatching { watching in log.withLock { $0.append(watching) } }
        feed.beginWatching()
        feed.beginWatching() // a second orb: no change
        feed.endWatching()
        XCTAssertEqual(log.withLock { $0 }, [true])
        feed.endWatching()
        feed.endWatching() // unbalanced: ignored
        XCTAssertEqual(log.withLock { $0 }, [true, false])
        feed.removeWatchObserver(id)
        feed.beginWatching()
        XCTAssertEqual(log.withLock { $0 }, [true, false])
        // reset keeps the watchers
        feed.reset()
        XCTAssertTrue(feed.wantsSamples)
    }

    func testResetKeepsWhetherAnyoneIsWatching() {
        let feed = LiveVoiceLevelFeed()
        feed.beginWatching()
        feed.pushInput(rms: 0.5, at: 1)
        feed.reset()
        XCTAssertTrue(feed.wantsSamples)
        XCTAssertNil(feed.inputRMS(at: 1))
    }
}

@MainActor
final class LiveVoiceLevelMeterTests: XCTestCase {
    private let dt = LiveVoiceLevelMeter.tickInterval

    /// RMS that maps to exactly 1.
    private var loud: Float { pow(10, LiveVoiceLevelScale.ceilingDecibels / 20) }

    private func meter(_ feed: LiveVoiceLevelFeed = LiveVoiceLevelFeed()) -> LiveVoiceLevelMeter {
        LiveVoiceLevelMeter(feed: feed, clock: { 0 })
    }

    /// Ticks `seconds` of synthetic time from `start`, feeding the microphone each tick.
    @discardableResult
    private func run(_ meter: LiveVoiceLevelMeter, from start: TimeInterval, seconds: TimeInterval, input: Float? = nil, output: Float? = nil) -> TimeInterval {
        var now = start
        let end = start + seconds
        while now < end - 1e-9 {
            now += dt
            if let input { meter.feed.pushInput(rms: input, at: now) }
            if let output { meter.feed.pushOutput(rms: output, at: now) }
            meter.tick(now: now)
        }
        return now
    }

    func testAttackIsFast() {
        let meter = meter()
        meter.route(phase: .listening)
        meter.tick(now: 0)
        // One 33 ms tick against the 40 ms time constant: 1 - e^(-1/1.2) of the way.
        meter.feed.pushInput(rms: loud, at: dt)
        meter.tick(now: dt)
        XCTAssertEqual(meter.level, Float(1 - exp(-dt / LiveVoiceLevelMeter.attack)), accuracy: 0.01)
        XCTAssertGreaterThan(meter.level, 0.5, "a syllable lands within a frame or two")
        run(meter, from: dt, seconds: 0.2, input: loud)
        XCTAssertEqual(meter.level, 1, accuracy: 0.02)
    }

    func testReleaseIsSlowerThanAttack() {
        let meter = meter()
        meter.route(phase: .listening)
        meter.tick(now: 0)
        let t = run(meter, from: 0, seconds: 0.5, input: loud)
        XCTAssertEqual(meter.level, 1, accuracy: 0.01)
        // The mic goes quiet but still reports: one release constant later, ~37%.
        run(meter, from: t, seconds: LiveVoiceLevelMeter.release, input: 0)
        XCTAssertEqual(meter.level, 0.37, accuracy: 0.1)
        XCTAssertGreaterThan(meter.level, 0.2, "release must be slower than the 40 ms attack")
    }

    func testDecaysToExactlyZeroWhenTheCallGoesIdle() {
        let meter = meter()
        meter.route(phase: .speaking)
        meter.tick(now: 0)
        let t = run(meter, from: 0, seconds: 0.4, output: loud)
        XCTAssertGreaterThan(meter.level, 0.9)
        meter.route(phase: .idle)
        run(meter, from: t, seconds: 2, output: loud)
        XCTAssertEqual(meter.level, 0)
        XCTAssertFalse(meter.isMeasuring)
        XCTAssertFalse(meter.isLoud)
    }

    func testMutedShowsTheAssistantAndNeverTheMicrophone() {
        let meter = meter()
        meter.route(phase: .muted)
        // A loud microphone while muted: nothing.
        run(meter, from: 0, seconds: 0.5, input: loud)
        XCTAssertEqual(meter.level, 0)
        // The assistant still shows.
        run(meter, from: 0.5, seconds: 0.5, input: loud, output: loud)
        XCTAssertGreaterThan(meter.level, 0.9)
        // Same through the muted flag on a listening phase.
        let flagged = self.meter()
        flagged.route(phase: .listening, isMicrophoneMuted: true)
        run(flagged, from: 0, seconds: 0.5, input: loud)
        XCTAssertEqual(flagged.level, 0)
    }

    func testSourceFollowsThePhase() {
        let meter = meter()
        // The assistant is quiet, the microphone loud.
        meter.route(phase: .speaking)
        run(meter, from: 0, seconds: 0.5, input: loud, output: 0)
        XCTAssertEqual(meter.level, 0)
        meter.route(phase: .listening)
        run(meter, from: 0.5, seconds: 0.5, input: loud, output: 0)
        XCTAssertGreaterThan(meter.level, 0.9)
    }

    func testIsMeasuringOnlyOnceTheSourceReports() {
        let meter = meter()
        meter.route(phase: .speaking)
        run(meter, from: 0, seconds: 0.3)
        XCTAssertFalse(meter.isMeasuring)
        XCTAssertFalse(meter.drivesOrb, "no samples yet: the phase's own swell stays in charge")
        run(meter, from: 0.3, seconds: 0.1, output: 0)
        XCTAssertTrue(meter.isMeasuring)
        XCTAssertTrue(meter.drivesOrb)
    }

    func testDrivesOrbWhileTheLevelDecays() {
        let meter = meter()
        meter.route(phase: .listening)
        let t = run(meter, from: 0, seconds: 0.3, input: loud)
        meter.route(phase: .ending)
        run(meter, from: t, seconds: 0.1)
        XCTAssertFalse(meter.isMeasuring)
        XCTAssertGreaterThan(meter.level, 0)
        XCTAssertTrue(meter.drivesOrb, "the tail is still the meter's, not an abrupt jump to the phase's 0")
    }

    func testFrameRatePolicy() {
        XCTAssertEqual(LiveVoiceLevelMeter.framesPerSecond(loud: true, lowPowerMode: false), 60)
        XCTAssertEqual(LiveVoiceLevelMeter.framesPerSecond(loud: false, lowPowerMode: false), 30)
        XCTAssertEqual(LiveVoiceLevelMeter.framesPerSecond(loud: true, lowPowerMode: true), 30, "Low Power Mode stays at 30")
    }

    func testLoudFlagHasHysteresis() {
        let meter = meter()
        meter.route(phase: .listening)
        let t = run(meter, from: 0, seconds: 0.3, input: loud)
        XCTAssertTrue(meter.isLoud)
        run(meter, from: t, seconds: 3, input: 0)
        XCTAssertFalse(meter.isLoud)
    }

    func testStopClearsTheLevelAndResumeShowsNoStaleSpike() {
        let meter = meter()
        meter.route(phase: .listening)
        meter.start()
        let t = run(meter, from: 0, seconds: 0.4, input: loud)
        XCTAssertGreaterThan(meter.level, 0.9)
        XCTAssertTrue(meter.isLoud)
        // The window is occluded: the meter stops, and what was shown is gone.
        meter.stop()
        XCTAssertEqual(meter.level, 0)
        XCTAssertFalse(meter.isLoud)
        XCTAssertFalse(meter.feed.wantsSamples)
        // Much later the window returns. The last mic sample is long stale: no spike.
        meter.start()
        meter.tick(now: t + 60)
        XCTAssertEqual(meter.level, 0)
        // And a fresh sample rises from 0 with the ordinary attack, one tick at a time.
        meter.feed.pushInput(rms: loud, at: t + 60 + dt)
        meter.tick(now: t + 60 + dt)
        XCTAssertEqual(meter.level, Float(1 - exp(-dt / LiveVoiceLevelMeter.attack)), accuracy: 0.01)
        meter.stop()
    }

    func testLeavingTheMicrophoneDropsItsTailAtOnce() {
        let meter = meter()
        meter.route(phase: .listening)
        run(meter, from: 0, seconds: 0.5, input: loud)
        XCTAssertGreaterThan(meter.level, 0.9)
        // Mute: the very next route, before any tick, shows nothing of the mic.
        meter.route(phase: .muted)
        XCTAssertEqual(meter.level, 0)
        run(meter, from: 0.5, seconds: 0.1, input: loud)
        XCTAssertEqual(meter.level, 0)
    }

    func testDeallocatingARunningMeterReleasesItsWatch() {
        let feed = LiveVoiceLevelFeed()
        var meter: LiveVoiceLevelMeter? = LiveVoiceLevelMeter(feed: feed)
        meter?.start()
        XCTAssertTrue(feed.wantsSamples)
        meter = nil
        XCTAssertFalse(feed.wantsSamples)
    }

    func testStartAndStopToggleWatching() {
        let feed = LiveVoiceLevelFeed()
        let meter = LiveVoiceLevelMeter(feed: feed)
        let second = LiveVoiceLevelMeter(feed: feed)
        meter.start()
        meter.start()
        XCTAssertTrue(meter.isRunning)
        XCTAssertTrue(feed.wantsSamples)
        // A call can show two orbs: one stopping does not stop the other's polling.
        second.start()
        second.stop()
        second.stop()
        XCTAssertTrue(feed.wantsSamples)
        meter.stop()
        XCTAssertFalse(meter.isRunning)
        XCTAssertFalse(feed.wantsSamples)
    }
}

@MainActor
final class LiveVoiceMeteredAudioTests: XCTestCase {
    private final class FakeInput: GeminiLiveAudioInput {
        var onChunk: (@MainActor (Data) -> Void)?
        var onInterrupted: (@MainActor () -> Void)?
        var cancelsEcho: Bool { true }
        var started = 0
        func requestPermission() async -> Bool { true }
        func start() throws { started += 1 }
        func stop() {}
    }

    private final class FakeOutput: GeminiLiveAudioOutput {
        var isPlaying = false
        var played = 0
        var interrupts = 0
        var stops = 0
        var muted = false
        func play(_ pcm: Data, sampleRate: Double) throws { played += 1 }
        func interrupt() { interrupts += 1 }
        func stop() { stops += 1 }
        func setMuted(_ muted: Bool) { self.muted = muted }
    }

    func testInputChunksReachTheControllerAndTheFeed() throws {
        let feed = LiveVoiceLevelFeed()
        feed.beginWatching()
        let base = FakeInput()
        let input = LiveVoiceMeteredAudioInput(base, feed: feed)
        var received: [Data] = []
        input.onChunk = { received.append($0) }
        XCTAssertNotNil(input.onChunk)
        let chunk = sinePCM16(amplitude: 0.5, frames: 320, sampleRate: 16_000)
        base.onChunk?(chunk)
        XCTAssertEqual(received, [chunk])
        XCTAssertEqual(try XCTUnwrap(feed.inputRMS(at: LiveVoiceLevelFeed.now)), 0.354, accuracy: 0.01)
        XCTAssertTrue(input.cancelsEcho)
        try input.start()
        XCTAssertEqual(base.started, 1)
        input.onChunk = nil
        XCTAssertNil(base.onChunk)
        XCTAssertNil(input.onChunk)
    }

    func testNothingIsMeasuredWhileNobodyWatches() throws {
        let feed = LiveVoiceLevelFeed()
        let baseIn = FakeInput()
        let input = LiveVoiceMeteredAudioInput(baseIn, feed: feed)
        var received = 0
        input.onChunk = { _ in received += 1 }
        baseIn.onChunk?(sinePCM16(amplitude: 0.5, frames: 320, sampleRate: 16_000))
        XCTAssertEqual(received, 1, "audio still flows")
        XCTAssertNil(feed.inputRMS())
        let baseOut = FakeOutput()
        let output = LiveVoiceMeteredAudioOutput(baseOut, feed: feed)
        try output.play(sinePCM16(amplitude: 0.5, frames: 4_800), sampleRate: 24_000)
        XCTAssertEqual(baseOut.played, 1)
        XCTAssertNil(feed.outputRMS())
    }

    func testOutputPlaysMetersAndClears() throws {
        let feed = LiveVoiceLevelFeed()
        feed.beginWatching()
        let base = FakeOutput()
        let output = LiveVoiceMeteredAudioOutput(base, feed: feed)
        try output.play(sinePCM16(amplitude: 0.5, frames: 4_800), sampleRate: 24_000)
        XCTAssertEqual(base.played, 1)
        XCTAssertNotNil(feed.outputRMS())
        output.interrupt()
        XCTAssertEqual(base.interrupts, 1)
        XCTAssertEqual(try XCTUnwrap(feed.outputRMS()), 0, "queued speech never plays after an interrupt")
        output.stop()
        XCTAssertEqual(base.stops, 1)
        XCTAssertNil(feed.outputRMS())
        output.setMuted(true)
        XCTAssertTrue(base.muted)
    }

    func testAFailedPlayDoesNotMeter() {
        struct Boom: Error {}
        final class Failing: GeminiLiveAudioOutput {
            var isPlaying = false
            func play(_ pcm: Data, sampleRate: Double) throws { throw Boom() }
            func interrupt() {}
            func stop() {}
            func setMuted(_ muted: Bool) {}
        }
        let feed = LiveVoiceLevelFeed()
        let output = LiveVoiceMeteredAudioOutput(Failing(), feed: feed)
        XCTAssertThrowsError(try output.play(sinePCM16(amplitude: 0.5, frames: 480), sampleRate: 24_000))
        XCTAssertNil(feed.outputRMS())
    }
}

final class WebRTCLevelSamplerTests: XCTestCase {
    private func stat(_ id: String, _ type: String, kind: String = "audio", level: Double? = nil, energy: Double? = nil, duration: Double? = nil) -> LiveVoiceRTCStat {
        var values: [String: Any] = ["kind": kind]
        if let level { values["audioLevel"] = NSNumber(value: level) }
        if let energy { values["totalAudioEnergy"] = NSNumber(value: energy) }
        if let duration { values["totalSamplesDuration"] = NSNumber(value: duration) }
        return LiveVoiceRTCStat(id: id, type: type, values: values)
    }

    func testRMSFromEnergyDeltas() throws {
        let sampler = WebRTCLevelSampler()
        // First report: no previous, falls back to the (trimmed) audioLevel.
        let first = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.4, energy: 1, duration: 10)])
        XCTAssertEqual(try XCTUnwrap(first.assistant), 0.2, accuracy: 1e-6)
        // 0.05 s later at RMS 0.1: energy grows by 0.1^2 * 0.05.
        let second = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.9, energy: 1 + 0.01 * 0.05, duration: 10.05)])
        XCTAssertEqual(try XCTUnwrap(second.assistant), 0.1, accuracy: 1e-4)
        XCTAssertNil(second.microphone)
    }

    func testMicrophoneComesFromMediaSource() throws {
        let sampler = WebRTCLevelSampler()
        _ = sampler.levels(from: [stat("mic", "media-source", energy: 0, duration: 0)])
        let levels = sampler.levels(from: [
            stat("mic", "media-source", energy: 0.04 * 0.1, duration: 0.1),
            stat("in", "inbound-rtp", level: 0.5),
        ])
        XCTAssertEqual(try XCTUnwrap(levels.microphone), 0.2, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(levels.assistant), 0.25, accuracy: 1e-6)
    }

    func testIgnoresVideoAndOtherTypes() {
        let sampler = WebRTCLevelSampler()
        let levels = sampler.levels(from: [
            stat("v", "inbound-rtp", kind: "video", level: 0.9),
            stat("t", "transport", level: 0.9),
            stat("m", "media-source", kind: "video", level: 0.9),
        ])
        XCTAssertEqual(levels, WebRTCLevelSampler.Levels(microphone: nil, assistant: nil))
    }

    func testShortIntervalOrResetCounterFallsBackToAudioLevel() throws {
        let sampler = WebRTCLevelSampler()
        _ = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.2, energy: 5, duration: 20)])
        // Almost no new audio: instantaneous level.
        let tiny = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.2, energy: 5.0001, duration: 20.001)])
        XCTAssertEqual(try XCTUnwrap(tiny.assistant), 0.1, accuracy: 1e-6)
        // A counter that went back: a new stream.
        let reset = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.2, energy: 0.1, duration: 25)])
        XCTAssertEqual(try XCTUnwrap(reset.assistant), 0.1, accuracy: 1e-6)
    }

    func testResetDropsTheLastReportSoAGapIsNotAveraged() throws {
        let sampler = WebRTCLevelSampler()
        _ = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.2, energy: 1, duration: 10)])
        sampler.reset()
        // Without a previous report the instantaneous level is used, not a delta over the pause.
        let after = sampler.levels(from: [stat("in", "inbound-rtp", level: 0.2, energy: 50, duration: 700)])
        XCTAssertEqual(try XCTUnwrap(after.assistant), 0.1, accuracy: 1e-6)
    }

    func testMissingEverythingReportsNothing() {
        let sampler = WebRTCLevelSampler()
        let levels = sampler.levels(from: [stat("in", "inbound-rtp")])
        XCTAssertNil(levels.assistant)
    }
}

final class LiquidOrbAudioMeasuredTests: XCTestCase {
    func testMeasuredBandsFollowTheLevel() {
        XCTAssertEqual(LiquidOrbAudio.measured(level: 0), LiquidOrbAudio())
        var last = LiquidOrbAudio.measured(level: 0)
        for level in stride(from: Float(0.1), through: 1, by: 0.1) {
            let next = LiquidOrbAudio.measured(level: level)
            XCTAssertGreaterThan(next.all, last.all)
            XCTAssertGreaterThan(next.high, last.high)
            last = next
        }
        XCTAssertEqual(LiquidOrbAudio.measured(level: 5), LiquidOrbAudio.measured(level: 1))
        XCTAssertEqual(LiquidOrbAudio.measured(level: .nan), LiquidOrbAudio())
    }
}

final class WebRTCStatsInFlightTests: XCTestCase {
    func testOneRequestAtATime() {
        let flight = WebRTCStatsInFlight(timeout: 1)
        XCTAssertTrue(flight.begin(at: 0))
        XCTAssertFalse(flight.begin(at: 0.5))
        flight.end()
        XCTAssertTrue(flight.begin(at: 0.6))
    }

    func testALostHandlerFreesItselfAfterTheTimeout() {
        let flight = WebRTCStatsInFlight(timeout: 1)
        XCTAssertTrue(flight.begin(at: 0))
        XCTAssertFalse(flight.begin(at: 0.9))
        XCTAssertTrue(flight.begin(at: 1.1), "the handler never answered: polling resumes")
    }
}
