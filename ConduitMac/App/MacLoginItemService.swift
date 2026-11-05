//
//  MacLoginItemService.swift
//  Conduit
//
//  Launch at login (D28). This is the one file that names SMAppService. The Settings model talks to
//  the MacLoginItemService protocol, and tests give it a fake: the test host is the real Conduit app,
//  so a real register() in a test would make the built test host open at the user's next login.
//  MacLaunchAtLoginTests checks that no other file names SMAppService.
//

import Foundation
import ServiceManagement

/// What the system reports for Conduit as a login item. Mirrors `SMAppService.Status`.
enum MacLoginItemStatus: Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user has not allowed it in System Settings > General > Login Items.
    case requiresApproval
    /// The system cannot find the app (a copy that was moved or deleted).
    case notFound
}

/// The part of `SMAppService.mainApp` that Launch at login uses.
@MainActor
protocol MacLoginItemService {
    var status: MacLoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// `SMAppService.mainApp` (macOS 13 and later; the Mac target is macOS 14, so no availability check).
struct MacLiveLoginItemService: MacLoginItemService {
    struct UnavailableUnderTest: Error {}

    /// Nil under XCTest: the host is the real app, and a test must not touch its login item.
    private static var service: SMAppService? { MacDefaults.isRunningUnderXCTest ? nil : .mainApp }

    /// True when this process never reaches the real service.
    static var isInert: Bool { service == nil }

    var status: MacLoginItemStatus {
        guard let service = Self.service else { return .notRegistered }
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }

    func register() throws {
        guard let service = Self.service else { throw UnavailableUnderTest() }
        try service.register()
    }

    func unregister() throws {
        guard let service = Self.service else { throw UnavailableUnderTest() }
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        guard Self.service != nil else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
