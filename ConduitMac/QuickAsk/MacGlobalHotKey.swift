import Carbon.HIToolbox
import Foundation

struct MacHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Option-Shift-Space. A value, so a recorder can replace it later.
enum MacQuickAskHotKey {
    static let `default` = MacHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
}

enum MacHotKeyRegistrationError: Error, Equatable {
    /// -9868 (eventInternalErr): macOS 15.0 and 15.1 reject Option / Option-Shift-only hotkeys.
    case unavailableOnThisMacOS
    /// eventHotKeyExistsErr: another app owns the combination.
    case conflict
    case other(Int32)

    static func map(_ status: OSStatus) -> MacHotKeyRegistrationError {
        let hotKeyExists = OSStatus(eventHotKeyExistsErr)
        switch status {
        case -9868: return .unavailableOnThisMacOS
        case hotKeyExists: return .conflict
        default: return .other(status)
        }
    }
}

@MainActor
protocol MacHotKeyRegistering: AnyObject {
    func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// Carbon RegisterEventHotKey: one combination, delivered while the app runs
/// in the background, consumed (Space is not typed into the front app), and no
/// Accessibility or Input Monitoring prompt.
@MainActor
final class MacCarbonHotKey: MacHotKeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?
    private static let signature: OSType = 0x51414B31 // 'QAK1'

    func register(_ key: MacHotKey, handler: @escaping @MainActor () -> Void) throws {
        unregister()
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let this = Unmanaged<MacCarbonHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in this.handler?() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installStatus == noErr else {
            self.handler = nil
            throw MacHotKeyRegistrationError.map(installStatus)
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            unregister()
            throw MacHotKeyRegistrationError.map(status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        handler = nil
    }
}
