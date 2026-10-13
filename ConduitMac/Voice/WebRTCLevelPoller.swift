import Foundation
import OSLog
import WebRTC

private let levelPollerLogger = Logger(subsystem: "com.milim.relay", category: "GPTLive")

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
/// libwebrtc's value tracks the peak, not the RMS.
final class WebRTCLevelSampler {
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

    private var previous: [String: Previous] = [:]

    func levels(from stats: [LiveVoiceRTCStat]) -> Levels {
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

/// Polls an `RTCPeerConnection`'s statistics every ~50 ms for the call's
/// audio levels and pushes them into the feed. RTCPeerConnection has no audio
/// sink to tap (no RTCAudioRenderer in this build), and WebRTC owns both audio
/// units, so the statistics are the way. It polls only while the orb is
/// watching (`LiveVoiceLevelFeed.wantsSamples`).
@MainActor
final class WebRTCLevelPoller {
    static let interval: Duration = .milliseconds(50)

    private weak var connection: RTCPeerConnection?
    private let feed: LiveVoiceLevelFeed
    private let sampler = WebRTCLevelSampler()
    private var task: Task<Void, Never>?
    private let inFlight = InFlight()

    init(connection: RTCPeerConnection, feed: LiveVoiceLevelFeed = .shared) {
        self.connection = connection
        self.feed = feed
    }

    func start() {
        guard task == nil else { return }
        feed.reset()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        feed.reset()
    }

    private func poll() {
        guard feed.wantsSamples, let connection, inFlight.begin() else { return }
        let feed = feed
        let inFlight = inFlight
        let sampler = sampler
        // WebRTC answers on its own thread: the sampler is only touched here,
        // one request at a time, and the feed is thread safe.
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

    /// At most one statistics request outstanding.
    private final class InFlight: @unchecked Sendable {
        private let flag = NSLock()
        private var busy = false

        func begin() -> Bool {
            flag.lock()
            defer { flag.unlock() }
            if busy { return false }
            busy = true
            return true
        }

        func end() {
            flag.lock()
            busy = false
            flag.unlock()
        }
    }
}
