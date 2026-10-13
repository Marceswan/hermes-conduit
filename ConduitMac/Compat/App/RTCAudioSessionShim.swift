import AVFoundation

/// The macOS WebRTC build has no RTCAudioSession: there is no shared audio
/// session to hand over, and its audio device module drives the hardware
/// directly. These carry the manual-audio calls upstream makes as no-ops.
final class RTCAudioSessionConfiguration {
    private static var current = RTCAudioSessionConfiguration()
    static func webRTC() -> RTCAudioSessionConfiguration { current }
    static func setWebRTC(_ configuration: RTCAudioSessionConfiguration) { current = configuration }

    var category = AVAudioSession.Category.playAndRecord.rawValue
    var mode = AVAudioSession.Mode.voiceChat.rawValue
    var categoryOptions: AVAudioSession.CategoryOptions = []
}

final class RTCAudioSession {
    private static let instance = RTCAudioSession()
    static func sharedInstance() -> RTCAudioSession { instance }

    var useManualAudio = false
    var isAudioEnabled = false
    func audioSessionDidActivate(_ session: AVAudioSession) {}
    func audioSessionDidDeactivate(_ session: AVAudioSession) {}
}
