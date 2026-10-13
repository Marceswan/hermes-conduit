import Foundation
import os

// The live call's audio level, for the orb (docs/macos/DECISIONS.md D8).
//
//   providers --push RMS--> LiveVoiceLevelFeed --read at ~30 Hz--> LiveVoiceLevelMeter --> orb
//
// Providers write what they already have (GPT-Live: WebRTC statistics;
// Gemini Live and Grok Live: the PCM16 chunks that cross their audio seams).
// The meter picks the source by call phase, maps it to 0...1 and smooths it.

/// Which audio the orb follows.
enum LiveVoiceLevelSource: Equatable {
    case none
    /// The assistant's voice.
    case assistant
    /// The user's microphone.
    case microphone
}

enum LiveVoiceLevelRouting {
    /// Speaking shows the assistant, listening the microphone. A muted call
    /// shows the assistant only: the microphone level never shows while muted.
    /// Connecting, idle, ending and failed follow nothing, so the level decays to 0.
    static func source(phase: LiveVoiceCallPhase, isMicrophoneMuted: Bool = false) -> LiveVoiceLevelSource {
        switch phase {
        case .speaking, .muted: return .assistant
        case .listening: return isMicrophoneMuted ? .assistant : .microphone
        case .connecting, .idle, .ending, .failed: return .none
        }
    }
}

enum LiveVoiceLevelScale {
    /// Quiet room noise and below reads as 0, a loud voice at the mic as 1.
    static let floorDecibels: Float = -50
    static let ceilingDecibels: Float = -10
    /// Above 1 so quiet syllables dip further below loud ones: more swing, less plateau.
    static let curveExponent: Float = 1.4

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-6))
    }

    /// RMS (full scale = 1) to a 0...1 level: dBFS mapped linearly between the
    /// floor and ceiling, then a gentle curve.
    static func level(rms: Float) -> Float {
        guard rms.isFinite else { return 0 }
        let span = ceilingDecibels - floorDecibels
        let linear = min(1, max(0, (decibels(rms: rms) - floorDecibels) / span))
        return pow(linear, curveExponent)
    }

    /// RMS of little-endian PCM16, full scale = 1. Safe on an odd length and on empty data.
    static func rms(pcm16 data: Data) -> Float {
        rms(pcm16: data, from: 0, frames: data.count / 2)
    }

    /// RMS of `frames` samples starting at sample `from`.
    static func rms(pcm16 data: Data, from: Int, frames: Int) -> Float {
        let available = data.count / 2
        let start = max(0, from)
        let count = min(frames, available - start)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            for index in start..<(start + count) {
                let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        return (sum / Float(count)).squareRoot()
    }
}

/// The latest levels, written by whichever thread a provider measures on and
/// read by the meter. All values are RMS, full scale = 1. A short critical
/// section guards a few scalars and one small array; nothing here runs on an
/// audio render thread (Gemini and Grok measure on the main actor, where
/// their chunks already arrive; GPT-Live on WebRTC's statistics callback).
final class LiveVoiceLevelFeed: @unchecked Sendable {
    static let shared = LiveVoiceLevelFeed()

    /// A level older than this is silence, not the last value.
    static let staleAfter: TimeInterval = 0.3
    /// Playback is measured in windows this long.
    static let windowDuration: TimeInterval = 0.02

    /// Monotonic seconds, the clock every `at:` parameter uses.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private struct Segment {
        var start: TimeInterval
        var hop: TimeInterval
        var values: [Float]
        var end: TimeInterval { start + hop * Double(values.count) }
    }

    private struct State {
        var input: Float = 0
        var inputAt: TimeInterval = 0
        var hasInput = false
        var instantOutput: Float = 0
        var instantOutputAt: TimeInterval = 0
        var hasOutput = false
        var segments: [Segment] = []
        var watchers = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether anything is looking at the level. A provider that has to poll
    /// for it (GPT-Live) polls only while this is set.
    var wantsSamples: Bool { state.withLock { $0.watchers > 0 } }

    /// A meter started or stopped looking; counted, because a call can show
    /// more than one orb.
    func beginWatching() { state.withLock { $0.watchers += 1 } }
    func endWatching() { state.withLock { $0.watchers = max(0, $0.watchers - 1) } }

    /// A new call (or the end of one): forgets every level, keeps the watchers.
    func reset() {
        state.withLock { current in
            let watchers = current.watchers
            current = State()
            current.watchers = watchers
        }
    }

    // MARK: Microphone

    func pushInput(rms: Float, at time: TimeInterval = LiveVoiceLevelFeed.now) {
        state.withLock {
            $0.input = rms
            $0.inputAt = time
            $0.hasInput = true
        }
    }

    func pushInput(pcm16 data: Data, at time: TimeInterval = LiveVoiceLevelFeed.now) {
        pushInput(rms: LiveVoiceLevelScale.rms(pcm16: data), at: time)
    }

    /// Nil until the microphone has reported once in this call; 0 when it has gone quiet.
    func inputRMS(at time: TimeInterval = LiveVoiceLevelFeed.now) -> Float? {
        state.withLock { current in
            guard current.hasInput else { return nil }
            return time - current.inputAt > Self.staleAfter ? 0 : current.input
        }
    }

    // MARK: Assistant

    /// A level measured as it plays (GPT-Live's statistics).
    func pushOutput(rms: Float, at time: TimeInterval = LiveVoiceLevelFeed.now) {
        state.withLock {
            $0.instantOutput = rms
            $0.instantOutputAt = time
            $0.hasOutput = true
        }
    }

    /// Model speech about to play (Gemini and Grok hand over PCM16 faster
    /// than it plays). Its windows are laid on a timeline that starts when
    /// the previous chunk ends, or now, so the level follows what is heard
    /// and not what has arrived.
    func pushOutput(pcm16 data: Data, sampleRate: Double, at time: TimeInterval = LiveVoiceLevelFeed.now) {
        let frames = data.count / 2
        guard frames > 0, sampleRate > 0 else { return }
        let windowFrames = max(1, Int((sampleRate * Self.windowDuration).rounded()))
        var values: [Float] = []
        values.reserveCapacity(frames / windowFrames + 1)
        var offset = 0
        while offset < frames {
            values.append(LiveVoiceLevelScale.rms(pcm16: data, from: offset, frames: windowFrames))
            offset += windowFrames
        }
        let hop = Double(windowFrames) / sampleRate
        state.withLock { current in
            // Whatever finished playing a second ago is no longer needed.
            current.segments.removeAll { $0.end < time - 1 }
            let start = max(time, current.segments.last?.end ?? time)
            current.segments.append(Segment(start: start, hop: hop, values: values))
            current.hasOutput = true
        }
    }

    /// The user cut in or the queue was dropped: queued speech never plays.
    func clearOutput() {
        state.withLock {
            $0.segments.removeAll()
            $0.instantOutput = 0
        }
    }

    /// The speaker side is done for the call.
    func resetOutput() {
        state.withLock {
            $0.segments.removeAll()
            $0.instantOutput = 0
            $0.hasOutput = false
        }
    }

    /// The assistant's RMS over the `window` seconds up to `time`; nil until
    /// the assistant has produced audio in this call, 0 in a gap.
    func outputRMS(at time: TimeInterval = LiveVoiceLevelFeed.now, window: TimeInterval = 0.04) -> Float? {
        state.withLock { current in
            guard current.hasOutput else { return nil }
            var sum: Float = 0
            var count = 0
            let from = time - window
            for segment in current.segments where segment.end > from && segment.start <= time {
                let low = max(0, Int(((from - segment.start) / segment.hop).rounded(.down)))
                let high = min(segment.values.count - 1, Int(((time - segment.start) / segment.hop).rounded(.down)))
                guard low <= high else { continue }
                for index in low...high {
                    sum += segment.values[index] * segment.values[index]
                    count += 1
                }
            }
            if count > 0 { return (sum / Float(count)).squareRoot() }
            if current.instantOutputAt > 0, time - current.instantOutputAt <= Self.staleAfter { return current.instantOutput }
            return 0
        }
    }
}

/// Smooths the feed into the 0...1 level the orb swells with, ticking at
/// about 30 Hz: it rises with a ~40 ms time constant and falls with ~200 ms,
/// so a syllable lands at once and the tail trails off like liquid settling.
@MainActor
final class LiveVoiceLevelMeter: ObservableObject {
    static let tickInterval: TimeInterval = 1.0 / 30
    static let attack: TimeInterval = 0.040
    static let release: TimeInterval = 0.200
    /// The orb draws at 60 fps while the level is above `loudThreshold`, and
    /// goes back to 30 below `quietThreshold` (a little under, so it does not flutter).
    static let loudThreshold: Float = 0.02
    static let quietThreshold: Float = 0.012

    /// Smoothed, 0...1.
    @Published private(set) var level: Float = 0
    /// The routed source has reported audio in this call. Until it does, the
    /// orb keeps the phase's own 0 or 1 swell.
    @Published private(set) var isMeasuring = false
    /// Above the 60 fps threshold.
    @Published private(set) var isLoud = false
    private(set) var source: LiveVoiceLevelSource = .none

    let feed: LiveVoiceLevelFeed
    private let clock: () -> TimeInterval
    private var lastTick: TimeInterval?
    private var smoothed: Float = 0
    private var timer: Timer?

    init(feed: LiveVoiceLevelFeed = .shared, clock: @escaping () -> TimeInterval = { LiveVoiceLevelFeed.now }) {
        self.feed = feed
        self.clock = clock
    }

    var isRunning: Bool { timer != nil }

    /// Whether the level, not the phase's own 0 or 1, should drive the orb: a
    /// source has reported, or the level is still decaying after one stopped.
    var drivesOrb: Bool { isMeasuring || level > 0 }

    func route(phase: LiveVoiceCallPhase, isMicrophoneMuted: Bool = false) {
        source = LiveVoiceLevelRouting.source(phase: phase, isMicrophoneMuted: isMicrophoneMuted)
    }

    func start() {
        guard timer == nil else { return }
        feed.beginWatching()
        lastTick = nil
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick(now: self.clock())
            }
        }
        // Common modes: the level keeps moving while a menu or a resize tracks.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        feed.endWatching()
    }

    /// One step. Internal for tests, which drive it with a synthetic clock.
    func tick(now: TimeInterval) {
        let measured: Float?
        switch source {
        case .none: measured = nil
        case .assistant: measured = feed.outputRMS(at: now)
        case .microphone: measured = feed.inputRMS(at: now)
        }
        let target = measured.map(LiveVoiceLevelScale.level(rms:)) ?? 0
        let delta = min(0.25, max(0, lastTick.map { now - $0 } ?? Self.tickInterval))
        lastTick = now
        let constant = target > smoothed ? Self.attack : Self.release
        smoothed += (target - smoothed) * Float(1 - exp(-delta / constant))
        if target == 0, smoothed < 0.002 { smoothed = 0 }
        // Views redraw per publish: skip changes nobody can see.
        if abs(smoothed - level) >= 0.002 || (smoothed == 0 && level != 0) { level = smoothed }
        let measuring = measured != nil
        if isMeasuring != measuring { isMeasuring = measuring }
        let loud = isLoud ? level >= Self.quietThreshold : level > Self.loudThreshold
        if isLoud != loud { isLoud = loud }
    }

    /// 60 only while the level is above the threshold, 30 otherwise and always
    /// in Low Power Mode (LiveVoiceOrbPower's policy, with the level as the cue).
    static func framesPerSecond(loud: Bool, lowPowerMode: Bool) -> Int {
        loud && !lowPowerMode ? 60 : 30
    }
}

extension LiquidOrbAudio {
    /// The bands for a measured level: the loudness is real, and the bands
    /// stay a little apart (highs need more energy than lows) so the swell
    /// reads as a voice and not a single pulse.
    static func measured(level: Float) -> LiquidOrbAudio {
        let clamped = level.isFinite ? max(0, min(1, level)) : 0
        return LiquidOrbAudio(
            low: clamped,
            mid: clamped * 0.9,
            high: clamped * clamped * 0.7 + clamped * 0.1,
            all: clamped
        )
    }
}
