import AVFoundation

/// macOS has no audio session. Category, mode, and activation succeed as
/// no-ops; permission maps to AVCaptureDevice; interruption and route
/// notifications exist but never fire on Mac.
final class AVAudioSession: NSObject {
    private static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }

    struct Category: RawRepresentable, Hashable {
        let rawValue: String
        static let ambient = Category(rawValue: "ambient")
        static let soloAmbient = Category(rawValue: "soloAmbient")
        static let playback = Category(rawValue: "playback")
        static let record = Category(rawValue: "record")
        static let playAndRecord = Category(rawValue: "playAndRecord")
        static let multiRoute = Category(rawValue: "multiRoute")
    }

    struct Mode: RawRepresentable, Hashable {
        let rawValue: String
        static let `default` = Mode(rawValue: "default")
        static let voiceChat = Mode(rawValue: "voiceChat")
        static let videoChat = Mode(rawValue: "videoChat")
        static let measurement = Mode(rawValue: "measurement")
        static let spokenAudio = Mode(rawValue: "spokenAudio")
        static let voicePrompt = Mode(rawValue: "voicePrompt")
    }

    struct CategoryOptions: OptionSet {
        let rawValue: UInt
        static let mixWithOthers = CategoryOptions(rawValue: 1 << 0)
        static let duckOthers = CategoryOptions(rawValue: 1 << 1)
        static let allowBluetooth = CategoryOptions(rawValue: 1 << 2)
        static let defaultToSpeaker = CategoryOptions(rawValue: 1 << 3)
        static let interruptSpokenAudioAndMixWithOthers = CategoryOptions(rawValue: 1 << 4)
        static let allowBluetoothA2DP = CategoryOptions(rawValue: 1 << 5)
        static let allowAirPlay = CategoryOptions(rawValue: 1 << 6)
        static let allowBluetoothHFP = CategoryOptions(rawValue: 1 << 7)
    }

    struct SetActiveOptions: OptionSet {
        let rawValue: UInt
        static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }

    enum InterruptionType: UInt { case began = 1, ended = 0 }
    struct InterruptionOptions: OptionSet {
        let rawValue: UInt
        static let shouldResume = InterruptionOptions(rawValue: 1)
    }
    enum RouteChangeReason: UInt {
        case unknown = 0, newDeviceAvailable, oldDeviceUnavailable, categoryChange,
             override, wakeFromSleep = 6, noSuitableRouteForCategory, routeConfigurationChange
    }
    enum PortOverride: UInt { case none = 0, speaker = 1936747378 }
    enum SilenceSecondaryAudioHintType: UInt { case begin = 1, end = 0 }
    enum RecordPermission { case undetermined, denied, granted }

    struct Port: RawRepresentable, Hashable {
        let rawValue: String
        static let builtInMic = Port(rawValue: "MicrophoneBuiltIn")
        static let builtInSpeaker = Port(rawValue: "Speaker")
        static let headphones = Port(rawValue: "Headphones")
        static let bluetoothHFP = Port(rawValue: "BluetoothHFP")
        static let bluetoothA2DP = Port(rawValue: "BluetoothA2DPOutput")
        static let usbAudio = Port(rawValue: "USBAudio")
        static let builtInReceiver = Port(rawValue: "Receiver")
        static let carAudio = Port(rawValue: "CarAudio")
    }

    final class PortDescription: NSObject {
        let portType: Port
        let portName: String
        let uid: String
        init(portType: Port, portName: String, uid: String) {
            self.portType = portType
            self.portName = portName
            self.uid = uid
        }
    }

    final class RouteDescription: NSObject {
        let inputs: [PortDescription]
        let outputs: [PortDescription]
        init(inputs: [PortDescription], outputs: [PortDescription]) {
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    static let interruptionNotification = Notification.Name("ConduitMac.AVAudioSession.interruption")
    static let routeChangeNotification = Notification.Name("ConduitMac.AVAudioSession.routeChange")
    static let mediaServicesWereResetNotification = Notification.Name("ConduitMac.AVAudioSession.mediaServicesReset")
    static let silenceSecondaryAudioHintNotification = Notification.Name("ConduitMac.AVAudioSession.silenceHint")

    private(set) var category: Category = .soloAmbient
    private(set) var mode: Mode = .default
    private(set) var categoryOptions: CategoryOptions = []

    func setCategory(_ category: Category, mode: Mode = .default, options: CategoryOptions = []) throws {
        self.category = category
        self.mode = mode
        self.categoryOptions = options
    }

    func setCategory(_ category: Category, options: CategoryOptions = []) throws {
        self.category = category
        self.categoryOptions = options
    }

    func setMode(_ mode: Mode) throws { self.mode = mode }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
    func setPreferredInput(_ input: PortDescription?) throws {}
    func overrideOutputAudioPort(_ portOverride: PortOverride) throws {}
    func setPreferredSampleRate(_ rate: Double) throws {}
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}

    var recordPermission: RecordPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestRecordPermission(_ response: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: response)
    }

    var currentRoute: RouteDescription {
        let input = AVCaptureDevice.default(for: .audio).map {
            PortDescription(portType: .builtInMic, portName: $0.localizedName, uid: $0.uniqueID)
        }
        let output = PortDescription(portType: .builtInSpeaker, portName: "Default Output", uid: "default-output")
        return RouteDescription(inputs: input.map { [$0] } ?? [], outputs: [output])
    }

    var availableInputs: [PortDescription]? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { PortDescription(portType: .builtInMic, portName: $0.localizedName, uid: $0.uniqueID) }
    }

    var sampleRate: Double { 48_000 }
    var inputNumberOfChannels: Int { 1 }
    var isOtherAudioPlaying: Bool { false }
    var secondaryAudioShouldBeSilencedHint: Bool { false }
}

// The notification user-info keys are declared unavailable on macOS in AVFAudio;
// same-named globals here shadow them. Notifications never fire on Mac, so the
// values only need to be stable strings.
let AVAudioSessionInterruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
let AVAudioSessionRouteChangeReasonKey = "AVAudioSessionRouteChangeReasonKey"
let AVAudioSessionSilenceSecondaryAudioHintTypeKey = "AVAudioSessionSilenceSecondaryAudioHintTypeKey"
