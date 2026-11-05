import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// The voice call, voice conversation and consent sheets on Mac (LC-A fix round 1). Same cause as the Settings sheet
/// (`MacSettingsSheetSizeTests`): the call screen, the consent sheet and the V2 layout of the classic voice screen
/// wrap their content in `readableContentWidth(ReadableWidth.call)`, a `GeometryReader` with no size of its own. A
/// Mac sheet takes the ideal size of its content, so each of them collapsed (hosted alone, 10 x 10 pt).
/// `RootView` gives each sheet an explicit Mac size.
@MainActor
final class MacCallSheetSizeTests: XCTestCase {
    private var fixture: MacSharedBaseAppStateFixture!
    private var appState: AppState { fixture.appState }

    override func setUp() {
        super.setUp()
        fixture = MacSharedBaseAppStateFixture()
    }

    override func tearDown() {
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    /// The size a sheet takes: the ideal size of its content.
    private func idealSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.environmentObject(appState))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func geminiSheet() -> GeminiLiveVoiceSheet {
        GeminiLiveVoiceSheet(controller: appState.geminiLiveController, jobs: appState.voiceBackgroundJobSupervisor,
                             appState: appState, onClose: {}, onRetry: {})
    }

    private func gptSheet() -> GPTLiveVoiceSheet {
        GPTLiveVoiceSheet(controller: appState.gptLiveController, jobs: appState.voiceBackgroundJobSupervisor,
                          appState: appState, onClose: {}, onRetry: {})
    }

    private func voiceConversationSheet() -> VoiceConversationSheet {
        VoiceConversationSheet(controller: appState.voiceConversationController,
                               backgroundJobs: appState.voiceBackgroundJobSupervisor, profile: "default",
                               appState: appState, onClose: {}, shouldAutoListen: { false }, startsListening: false)
    }

    // MARK: The sizes

    private func assertCallSize(_ size: CGSize, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width, MacCallSheet.idealWidth, accuracy: 0.5, "\(name) width", file: file, line: line)
        XCTAssertEqual(size.height, max(MacCallSheet.minHeight, MacCallSheet.idealHeight), accuracy: 0.5, "\(name) height", file: file, line: line)
        XCTAssertGreaterThan(size.height, 400, "\(name): a sheet this short shows no call (it was 10 pt)", file: file, line: line)
    }

    func testTheCallColumnIsTheWidthOfTheCallSheets() {
        XCTAssertEqual(MacCallSheet.idealWidth, ReadableWidth.call, "no margins inside the sheet")
        XCTAssertGreaterThanOrEqual(MacCallSheet.idealWidth, MacCallSheet.minWidth)
        XCTAssertGreaterThanOrEqual(MacCallSheet.consentIdealWidth, MacCallSheet.consentMinWidth)
    }

    func testTheGeminiGrokAndLocalCallSheetHasTheMacCallSize() {
        assertCallSize(idealSize(geminiSheet().macCallSheetSize()), "Gemini, Grok and Local")
    }

    func testTheGPTCallSheetHasTheMacCallSize() {
        assertCallSize(idealSize(gptSheet().macCallSheetSize()), "GPT-Live")
    }

    func testTheVoiceConversationSheetHasTheMacCallSize() {
        assertCallSize(idealSize(voiceConversationSheet().macCallSheetSize()), "voice conversation")
    }

    func testTheConsentSheetHasTheMacConsentSize() {
        let size = idealSize(LiveVoiceConsentSheet(mode: .gptLive, onAnswer: { _ in }).macCallConsentSheetSize())
        XCTAssertEqual(size.width, MacCallSheet.consentIdealWidth, accuracy: 0.5)
        XCTAssertEqual(size.height, MacCallSheet.consentIdealHeight, accuracy: 0.5)
    }

    func testTheClassicVoiceCardSheetHasTheMacCardSize() {
        let size = idealSize(LiveVoiceScreenCardSheet(title: "On screen", markdown: "hello").macCardSheetSize())
        XCTAssertEqual(size.width, MacCardSheet.idealWidth, accuracy: 0.5)
        XCTAssertEqual(size.height, MacCardSheet.idealHeight, accuracy: 0.5)
    }

    // MARK: RootView applies them

    private func rootViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Conduit/Views/RootView.swift"), encoding: .utf8)
    }

    /// The modifiers of the sheet whose content starts at `marker`, up to `end` (the sheet closure's own closing
    /// brace). Each must carry a tagged Mac region with the size.
    private func assertSheet(_ marker: String, endsAt end: String, hasSize modifier: String, in text: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let start = try XCTUnwrap(text.range(of: marker), "sheet not found: \(marker)", file: file, line: line)
        let tail = text[start.upperBound...]
        let stop = try XCTUnwrap(tail.range(of: end), "end of the sheet closure: \(marker)", file: file, line: line)
        let chain = String(tail[..<stop.lowerBound])
        XCTAssertTrue(chain.contains("#if os(macOS) // MAC:"), "\(marker): no tagged Mac region", file: file, line: line)
        XCTAssertTrue(chain.contains(modifier), "\(marker): no \(modifier)", file: file, line: line)
        XCTAssertTrue(chain.contains("#endif // MAC:"), "\(marker): the Mac region is not closed", file: file, line: line)
    }

    func testRootViewGivesEveryCallSheetTheMacCallSize() throws {
        let text = try rootViewSource()
        let end = "\n        }\n"
        for marker in ["GeminiLiveVoiceSheet(\n                controller: appState.geminiLiveController",
                       "controller: appState.grokLiveController",
                       "controller: appState.localLiveController",
                       "GPTLiveVoiceSheet("] {
            try assertSheet(marker, endsAt: end, hasSize: ".macCallSheetSize()", in: text)
        }
    }

    func testRootViewGivesTheVoiceConversationSheetTheMacCallSize() throws {
        let text = try rootViewSource()
        // The sheet holds the Classic card's own sheet, which has its own size: take the part after it.
        let start = try XCTUnwrap(text.range(of: "VoiceConversationSheet(\n                controller:"))
        let tail = String(text[start.upperBound...])
        let stop = try XCTUnwrap(tail.range(of: "\n        }\n"))
        let sheet = String(tail[..<stop.lowerBound])
        let card = try XCTUnwrap(sheet.range(of: ".macCardSheetSize()"), "the Classic card's sheet")
        let afterCard = try XCTUnwrap(sheet[card.upperBound...].range(of: "\n                }\n"), "end of the Classic card's sheet")
        let own = String(sheet[afterCard.upperBound...])
        XCTAssertTrue(own.contains("#if os(macOS) // MAC:"), "no tagged Mac region")
        XCTAssertTrue(own.contains(".macCallSheetSize()"), "the voice conversation sheet has no Mac size")
        XCTAssertTrue(own.contains("#endif // MAC:"), "the Mac region is not closed")
    }

    func testRootViewGivesTheConsentSheetTheMacConsentSize() throws {
        try assertSheet("LiveVoiceConsentSheet(mode: mode)", endsAt: "\n        }\n",
                        hasSize: ".macCallConsentSheetSize()", in: try rootViewSource())
    }

    func testRootViewGivesTheClassicVoiceCardSheetTheMacCardSize() throws {
        try assertSheet("LiveVoiceScreenCardSheet(title: card.title", endsAt: "\n                }\n",
                        hasSize: ".macCardSheetSize()", in: try rootViewSource())
    }
}
