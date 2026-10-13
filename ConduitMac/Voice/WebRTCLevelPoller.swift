import Foundation
import WebRTC

/// One entry of an `RTCStatisticsReport`, reduced to what the sampler reads.
struct LiveVoiceRTCStat {
    var id: String
    /// `RTCStatistics.type`: "inbound-rtp" for the model's audio arriving,
    /// "media-source" for the microphone as captured.
    var type: String
    /// `RTCStatistics.values`: NSNumber or NSString entries keyed by the W3C
    /// stats member names.
    var values: [String: Any]
}

/// Turns statistics reports into RMS levels. The real RMS is the root of the
/// energy accumulated since the last report over the time it covers
/// (`totalAudioEnergy` / `totalSamplesDuration` deltas); when a report lacks
/// them the instantaneous `audioLevel` stands in, trimmed 6 dB because
/// libwebrtc's value tracks the peak, not the RMS. The poller calls it from
/// WebRTC's thread, one request at a time; the lock makes `reset` (main
/// thread, on resuming after a pause) safe against that.
final class WebRTCLevelSampler: @unchecked Sendable {
    struct Levels: Equatable {
        var microphone: Float?
        var assistant: Float?
    }

    static let peakTrim: Float = 0.5
    /// Reports closer together than this carry too little audio to divide by.
    static let minimumDuration = 0.005

    private struct Previous {
        var energy: Double
        var duration: Double
    }

    private let lock = NSLock()
    private var previous: [String: Previous] = [:]

    /// Forgets the last reports: after a pause the energy delta would span the whole gap.
    func reset() {
        lock.lock()
        previous = [:]
        lock.unlock()
    }

    func levels(from stats: [LiveVoiceRTCStat]) -> Levels {
        lock.lock()
        defer { lock.unlock() }
        var result = Levels()
        for stat in stats {
            guard Self.isAudio(stat) else { continue }
            switch stat.type {
            case "inbound-rtp": result.assistant = Self.louder(result.assistant, level(of: stat))
            case "media-source": result.microphone = Self.louder(result.microphone, level(of: stat))
            default: continue
            }
        }
        return result
    }

    private static func isAudio(_ stat: LiveVoiceRTCStat) -> Bool {
        let kind = (stat.values["kind"] ?? stat.values["mediaType"]) as? String
        return kind == "audio"
    }

    private static func louder(_ first: Float?, _ second: Float?) -> Float? {
        switch (first, second) {
        case let (first?, second?): return max(first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }

    private func level(of stat: LiveVoiceRTCStat) -> Float? {
        let energy = (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue
        let duration = (stat.values["totalSamplesDuration"] as? NSNumber)?.doubleValue
        let instantaneous = (stat.values["audioLevel"] as? NSNumber).map { Float(truncating: $0) * Self.peakTrim }
        guard let energy, let duration else { return instantaneous }
        defer { previous[stat.id] = Previous(energy: energy, duration: duration) }
        guard let last = previous[stat.id] else { return instantaneous }
        let elapsed = duration - last.duration
        // A counter that went backwards is a new stream; too little audio to divide by is no news.
        guard elapsed >= Self.minimumDuration, energy >= last.energy else { return instantaneous }
        return Float(((energy - last.energy) / elapsed).squareRoot())
    }
}

/// At most one statistics request outstanding. A request whose handler never
/// answers frees itself after `timeout`, so one lost callback cannot stall the
/// level for the rest of the call.
final class WebRTCStatsInFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: TimeInterval?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 1) {
        self.timeout = timeout
    }

    func begin(at now: TimeInterval = LiveVoiceLevelFeed.now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let startedAt, now - startedAt < timeout { return false }
        startedAt = now
        return true
    }

    func end() {
        lock.lock()
        startedAt = nil
        lock.unlock()
    }
}

/// Polls an `RTCPeerConnection`'s statistics every ~50 ms for the call's
/// audio levels and pushes them into the feed. RTCPeerConnection has no audio
/// sink to tap (no RTCAudioRenderer in this build), and WebRTC owns both audio
/// units, so the statistics are the way. It polls only while an orb is
/// watching (`LiveVoiceLevelFeed.wantsSamples`): the loop is started and
/// cancelled by the feed's watch signal, so an unwatched call (window
/// occluded, sheet closed) costs no wakeups at all.
@MainActor
final class WebRTCLevelPoller {
    static let interval: Duration = .milliseconds(50)

    private weak var connection: RTCPeerConnection?
    private let feed: LiveVoiceLevelFeed
    private let sampler = WebRTCLevelSampler()
    private let inFlight = WebRTCStatsInFlight()
    private var loop: Task<Void, Never>?
    private var observer: UUID?
    private var isStarted = false

    init(connection: RTCPeerConnection, feed: LiveVoiceLevelFeed = .shared) {
        self.connection = connection
        self.feed = feed
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        feed.reset()
        observer = feed.observeWatching { [weak self] _ in
            // Told on whichever thread flipped it; decided on the main actor.
            Task { @MainActor [weak self] in self?.watchingChanged() }
        }
        watchingChanged()
    }

    func stop() {
        isStarted = false
        if let observer { feed.removeWatchObserver(observer) }
        observer = nil
        loop?.cancel()
        loop = nil
        feed.reset()
    }

    private func watchingChanged() {
        guard isStarted, feed.wantsSamples else {
            loop?.cancel()
            loop = nil
            return
        }
        guard loop == nil else { return }
        // Resuming: an energy delta must not span the pause.
        sampler.reset()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        guard let connection, inFlight.begin() else { return }
        let feed = feed
        let inFlight = inFlight
        let sampler = sampler
        // WebRTC answers on its own thread: the sampler locks, the feed is thread safe.
        connection.statistics { report in
            defer { inFlight.end() }
            let stats = report.statistics.values.map {
                LiveVoiceRTCStat(id: $0.id, type: $0.type, values: $0.values)
            }
            let levels = sampler.levels(from: stats)
            let now = LiveVoiceLevelFeed.now
            if let microphone = levels.microphone { feed.pushInput(rms: microphone, at: now) }
            if let assistant = levels.assistant { feed.pushOutput(rms: assistant, at: now) }
        }
    }
}
