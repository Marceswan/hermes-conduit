import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ConduitMac

@MainActor
final class MacAskAboutWindowTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var state: AppState!

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAskAboutWindowTests.\(UUID().uuidString)", isDirectory: true)
        state = AppState(
            defaults: suite.defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: suite.defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: suite.defaults,
                avatarsRoot: scratch.appendingPathComponent("appearance", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
        state.widgetSnapshotStoreOverride = WidgetSnapshotStore(directory: scratch.appendingPathComponent("widgets", isDirectory: true))
        state.widgetSnapshotReloadOverride = {}
        state.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
    }

    override func tearDown() async throws {
        state.pendingScreenshots.forEach { state.discardPendingScreenshot(forSession: $0.sessionID) }
        state = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private static var tinyPNG: Data {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    func testCancelledIsSilent() async {
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.cancelled, appState: state, limitMegabytes: 16)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.pendingScreenshot(forSession: "s1"))
    }

    func testFailureSetsLocalizedErrorAndDoesNotAttach() async {
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.failed(.noPicture), appState: state, limitMegabytes: 16)
        XCTAssertEqual(state.errorMessage, MacAskAboutWindowMessage.message(for: .noPicture))
        XCTAssertNil(state.pendingScreenshot(forSession: "s1"))
    }

    func testEachFailureHasItsOwnMessage() {
        let messages = [MacWindowCaptureMath.Failure.pickerFailed, .noPicture, .encodeFailed]
            .map { MacAskAboutWindowMessage.message(for: $0) }
        XCTAssertEqual(Set(messages).count, 3)
        XCTAssertFalse(messages.contains(""))
    }

    func testTooLargeUsesExistingMessage() async {
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.tooLarge(suggestedName: "Safari"), appState: state, limitMegabytes: 8)
        XCTAssertEqual(state.errorMessage, AttachmentSizeLimit.tooLargeMessage(names: ["Safari"], megabytes: 8))
        XCTAssertNil(state.pendingScreenshot(forSession: "s1"))
    }

    func testCapturedStagesIntoActiveSession() async {
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.captured(data: Self.tinyPNG, isJPEG: false, suggestedName: "Window"),
                                       appState: state, limitMegabytes: 16)
        XCTAssertNotNil(state.pendingScreenshot(forSession: "s1"))
        XCTAssertNil(state.errorMessage)
    }

    func testUndecodableDataSurfacesEncodeFailure() async {
        state.activeSessionId = "s1"
        await MacAskAboutWindow.attach(.captured(data: Data([1, 2, 3]), isJPEG: false, suggestedName: "Window"),
                                       appState: state, limitMegabytes: 16)
        XCTAssertEqual(state.errorMessage, MacAskAboutWindowMessage.message(for: .encodeFailed))
        XCTAssertNil(state.pendingScreenshot(forSession: "s1"))
    }

    func testNoChatAndNoConnectionDoesNotStageAndSaysWhy() async {
        // Offline `createNewSession` starts nothing, so the capture has no chat to land in.
        state.activeSessionId = nil
        await MacAskAboutWindow.attach(.captured(data: Self.tinyPNG, isJPEG: false, suggestedName: "Window"),
                                       appState: state, limitMegabytes: 16)
        XCTAssertTrue(state.pendingScreenshots.isEmpty)
        XCTAssertNotNil(state.errorMessage)
    }
}
