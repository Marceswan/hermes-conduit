import Contacts
import Foundation

// Mac twins of the iOS-only phone sources (R3). Calendar and phone sharing is
// kept off on Mac (showsPhoneSettings is false), so nothing reaches these in
// the app; they exist so the shared phone sync code compiles.

/// Twin of Conduit/Phone/PhoneStatusSource.swift DevicePhoneStatusSource.
/// A Mac shares no phone status: no battery, motion or CarPlay state.
@MainActor
final class DevicePhoneStatusSource: PhoneStatusSource {
    func snapshot() async -> [String: Any] { [:] }
    func requestMotionAccess() async {}
}

/// Twin of Conduit/Phone/PhonePeople.swift PhoneContactPicker. The system
/// contact picker view controller is unavailable on macOS: it picks no one.
@MainActor
final class PhoneContactPicker: NSObject {
    static func present(_ picked: @escaping ([CNContact]) -> Void) {}
}
