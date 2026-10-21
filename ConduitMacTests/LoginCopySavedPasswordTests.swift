import XCTest

/// The frozen sign-in copies in ConduitMac/Login clear a dashboard's saved
/// password where a browser or single sign-on login leaves none to reuse, and
/// where a sign-in chooses not to save it. Since upstream #1075 a successful
/// Face ID or Touch ID unlock holds for the saved password while Conduit
/// runs, and only `AppState.clearSavedPassword(dashboardID:)` drops that hold
/// together with the password. The copies must go through it, as upstream's
/// `LoginFlowModel` and `ConnectionSetupApplication` do.
final class LoginCopySavedPasswordTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func copies() throws -> [(name: String, source: String)] {
        let dir = repoRoot.appendingPathComponent("ConduitMac/Login")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoCopyClearsTheKeychainPasswordBehindTheHeldUnlock() throws {
        for (name, source) in try copies() {
            XCTAssertFalse(
                source.contains("KeychainHelper.clearCredentials(dashboardID"),
                "\(name) clears the saved password without dropping the held Face ID unlock; call appState.clearSavedPassword(dashboardID:)"
            )
        }
    }

    func testTheSignInCopyClearsThroughAppState() throws {
        let login = try XCTUnwrap(try copies().first { $0.name == "LoginView.swift" })
        let count = login.source.components(separatedBy: "appState.clearSavedPassword(dashboardID: dashboardID)").count - 1
        XCTAssertEqual(count, 2, "the browser sign-in and the no-save sign-in")
    }
}
