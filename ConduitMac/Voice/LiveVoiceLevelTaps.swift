import Foundation

// Gemini Live and Grok Live share one controller, and every sample of their
// audio crosses two seams: the microphone's PCM16 chunks (GeminiLiveAudioInput)
// and the model's (GeminiLiveAudioOutput). Wrapping the seams measures both
// directions of both audio kinds (the default capture and playback services,
// and the echo-cancelling engine) without a second installTap on any bus.
// GeminiLiveConversationController wraps its input and output on Mac only.

@MainActor
final class LiveVoiceMeteredAudioInput: GeminiLiveAudioInput {
    private let base: GeminiLiveAudioInput
    private let feed: LiveVoiceLevelFeed
    private var handler: (@MainActor (Data) -> Void)?

    init(_ base: GeminiLiveAudioInput, feed: LiveVoiceLevelFeed = .shared) {
        self.base = base
        self.feed = feed
    }

    var onChunk: (@MainActor (Data) -> Void)? {
        get { handler }
        set {
            handler = newValue
            guard let newValue else {
                base.onChunk = nil
                return
            }
            let feed = feed
            base.onChunk = { chunk in
                // Nothing watching: the chunk goes straight on, unmeasured.
                if feed.wantsSamples { feed.pushInput(pcm16: chunk) }
                newValue(chunk)
            }
        }
    }

    var onInterrupted: (@MainActor () -> Void)? {
        get { base.onInterrupted }
        set { base.onInterrupted = newValue }
    }

    var cancelsEcho: Bool { base.cancelsEcho }
    func requestPermission() async -> Bool { await base.requestPermission() }
    func start() throws { try base.start() }
    func stop() { base.stop() }
}

@MainActor
final class LiveVoiceMeteredAudioOutput: GeminiLiveAudioOutput {
    private let base: GeminiLiveAudioOutput
    private let feed: LiveVoiceLevelFeed

    init(_ base: GeminiLiveAudioOutput, feed: LiveVoiceLevelFeed = .shared) {
        self.base = base
        self.feed = feed
    }

    var isPlaying: Bool { base.isPlaying }

    func play(_ pcm: Data, sampleRate: Double) throws {
        try base.play(pcm, sampleRate: sampleRate)
        if feed.wantsSamples { feed.pushOutput(pcm16: pcm, sampleRate: sampleRate) }
    }

    func interrupt() {
        base.interrupt()
        feed.clearOutput()
    }

    func stop() {
        base.stop()
        feed.resetOutput()
    }

    func setMuted(_ muted: Bool) { base.setMuted(muted) }
}
