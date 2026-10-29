//
//  MacXCTestDefaults.swift
//  Conduit
//
//  Under XCTest the Mac test host is the real app, so its shared stores run in the user's own
//  defaults domain. A store that the host's root view binds to the host's AppState saves what a
//  test does to that AppState: ChatAttachmentDropTests opened "drop-test-..." chats and left
//  those tabs in the user's tab strip. A shared store asks for its defaults here: the standard
//  domain in the app, a suite of its own under XCTest. ConduitMacTests/TestDefaultsIsolation.swift
//  checks the user's domain after every test.
//

#if DEBUG
import Foundation

enum MacXCTestDefaults {
    /// One folder per test process under the temporary directory.
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit.mac.xctest.defaults.\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// `UserDefaults.standard` in the app. Under XCTest, the suite `name`, which lives in this process's folder.
    /// The suite is named by a path, so cfprefsd keeps its plist there, not in ~/Library/Preferences, where a
    /// plist that is deleted comes back.
    static func standardOrTestSuite(_ name: String) -> UserDefaults {
        guard MacDefaults.isRunningUnderXCTest else { return .standard }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appendingPathComponent(name).path)!
    }

    /// Deletes the folder (MacTestKeychainGuard calls it when the test bundle ends).
    static func removeTestSuites() {
        try? FileManager.default.removeItem(at: folder)
    }
}
#endif
