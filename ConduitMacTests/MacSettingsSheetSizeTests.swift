import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The Settings sheet on Mac (live check F1: it opened 470 x 80 pt). Upstream's `SettingsView` wraps its
/// pages in `readableContentWidth` (a `GeometryReader`), which has no size of its own, so a Mac sheet that
/// takes the ideal size of its content collapsed. `RootView` gives the sheet an explicit Mac size.
@MainActor
final class MacSettingsSheetSizeTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!

    override func setUp() {
        super.setUp()
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() {
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    private func settingsView() -> some View {
        let appState = fixture.appState
        return SettingsView(
            snapshot: appState.makeSettingsSnapshot(),
            saveTheme: { _ in },
            persistBusyInputMode: { _ in true },
            persistChatResumeBehavior: { _ in },
            persistChatReturnSurface: { _ in },
            loadProfileSettings: { _ in [:] },
            persistProfileSetting: { _, _ in true },
            loadProfileConfigOptions: { ProfileConfigOptions() },
            loadProfileModelDefaults: { nil },
            persistProfileMainModel: { _, _, _ in true },
            saveDefaultProfileName: { _ in },
            reconnect: { false },
            disconnect: {}
        )
        .environmentObject(appState)
    }

    /// The size a sheet takes: the ideal size of its content.
    private func idealSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testTheSettingsPagesHaveTheMacSheetSize() {
        let size = idealSize(settingsView().macSettingsSheetSize())
        XCTAssertEqual(size.width, MacSettingsSheet.idealWidth, accuracy: 0.5)
        XCTAssertEqual(size.height, max(MacSettingsSheet.minHeight, MacFormSheet.idealHeight), accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 400, "a sheet this short shows no page (it was 80 pt)")
    }

    // MARK: RootView applies it

    func testRootViewGivesTheSettingsSheetTheMacSize() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Conduit/Views/RootView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "SettingsView(\n                snapshot: snapshot"), "Settings sheet not found")
        let tail = text[start.upperBound...]
        // The sheet's content closure ends at the next closing brace at the sheet's own indent.
        let end = try XCTUnwrap(tail.range(of: "\n        }\n"), "end of the Settings sheet closure")
        let chain = String(tail[..<end.lowerBound])
        XCTAssertTrue(chain.contains("#if os(macOS) // MAC:"), "no tagged Mac region in the Settings sheet's modifiers")
        XCTAssertTrue(chain.contains(".macSettingsSheetSize()"), "the Settings sheet has no Mac size")
        XCTAssertTrue(chain.contains("#endif"), "the Mac region is not closed")
    }
}
