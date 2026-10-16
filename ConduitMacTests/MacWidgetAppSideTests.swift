import XCTest
@testable import ConduitMac

/// The Mac app's half of the widget hand-off (D25): which app group the
/// snapshot goes to, that the app declares it, that the `conduit` scheme is
/// registered so a widget tap reaches the app, and that a language change
/// republishes the widget copy. The extension half is MacWidgetsEmbeddingTests.
@MainActor
final class MacWidgetAppSideTests: XCTestCase {
    static let teamGroup = "58XKRG9VMA.com.meswan.hermes.mac.widgets"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }

    func testMacAppGroupIsTeamPrefixedNotGroupPrefixed() {
        XCTAssertEqual(WidgetSnapshotStore.appGroup, Self.teamGroup)
        XCTAssertFalse(WidgetSnapshotStore.appGroup.hasPrefix("group."))
    }

    func testAppEntitlementsDeclareTheGroupAndStayUnsandboxed() throws {
        let entitlements = try plist("ConduitMac/Resources/ConduitMac.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], [Self.teamGroup])
        XCTAssertNil(entitlements["com.apple.security.app-sandbox"], "only the widget extension is sandboxed")
        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true, "existing entitlements are kept")
        XCTAssertEqual(entitlements["com.apple.security.device.camera"] as? Bool, true)
    }

    func testInfoPlistRegistersTheConduitScheme() throws {
        let info = try plist("ConduitMac/Resources/Info.plist")
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, ["conduit"])
    }

    func testLanguageChangeHandlerRepublishesTheWidgetLanguage() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("ConduitMac/App/ConduitMacApp.swift"), encoding: .utf8)
        let range = try XCTUnwrap(source.range(of: ".onChange(of: appLanguage.selection)"))
        let handler = source[range.upperBound...].prefix(400)
        XCTAssertTrue(handler.contains("appState.publishWidgetLanguage()"))
    }

    func testPublishWidgetLanguageRewritesTheStoredLanguageAndReloadsOnce() throws {
        let fixture = MacSharedBaseAppStateFixture()
        defer { fixture.tearDown() }
        let directory = fixture.scratch.appendingPathComponent("widgets", isDirectory: true)
        let store = WidgetSnapshotStore(directory: directory)
        try store.write(WidgetSnapshot(appLanguage: "zz-stale", currentWorkspaceID: nil, workspaces: []))
        var reloads = 0
        fixture.appState.widgetSnapshotReloadOverride = { reloads += 1 }

        fixture.appState.publishWidgetLanguage()

        XCTAssertEqual(store.read()?.appLanguage, AppLanguageStore.shared.selection.rawValue)
        XCTAssertEqual(reloads, 1)
    }
}
