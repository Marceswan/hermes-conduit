import XCTest
@testable import ConduitMac

/// D25: the Mac widget extension is embedded, versioned like the app, shares
/// the app's group, is sandboxed, and is built from the iOS sources.
final class MacWidgetsEmbeddingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appexURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("ConduitMacWidgets.appex")
    }

    func testHostAppEmbedsTheWidgetExtension() throws {
        let url = try XCTUnwrap(appexURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) is missing")
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "com.meswan.hermes.mac.widgets")
        let ext = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
    }

    func testExtensionIdIsAChildOfTheAppIdAndVersionsMatch() throws {
        let bundle = try XCTUnwrap(appexURL.flatMap { Bundle(url: $0) })
        let appID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(try XCTUnwrap(bundle.bundleIdentifier).hasPrefix(appID + "."))
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let app = try XCTUnwrap(Bundle.main.infoDictionary?[key] as? String, key)
            let ext = try XCTUnwrap(bundle.infoDictionary?[key] as? String, key)
            XCTAssertEqual(ext, app, "\(key) must match the app (Sparkle replaces both together)")
        }
    }

    func testExtensionEntitlementsAreSandboxedAndShareTheAppGroup() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("ConduitMacWidgets/ConduitMacWidgets.entitlements"))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], [WidgetSnapshotStore.appGroup])
    }

    func testExtensionIsBuiltFromSharedIOSSourcesNotCopies() throws {
        let folder = repoRoot.appendingPathComponent("ConduitMacWidgets")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["ConduitMacWidgets.entitlements", "Info.plist"])
        let project = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let block = try XCTUnwrap(project.range(of: "  ConduitMacWidgets:\n"))
        let target = String(project[block.lowerBound...].prefix(1800))
        XCTAssertTrue(target.contains("- path: ConduitWidgets\n"))
        XCTAssertTrue(target.contains("- path: Shared/Widgets\n"))
    }
}
