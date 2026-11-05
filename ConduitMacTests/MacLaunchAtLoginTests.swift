import AppKit
import XCTest
@testable import ConduitMac

/// A login item service that answers from memory. Every test in this file uses it; none calls the real
/// `SMAppService` (that would register the test host, the real Conduit app, as a login item).
@MainActor
final class FakeLoginItemService: MacLoginItemService {
    struct Refused: Error {}

    var status: MacLoginItemStatus
    /// What the system reports after a `register()` that does not throw.
    var statusAfterRegister: MacLoginItemStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: MacLoginItemStatus = .notRegistered) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() { openSettingsCount += 1 }
}

/// D28: Conduit opens at login only when the user turns it on, and the system's answer is the only state.
@MainActor
final class MacLaunchAtLoginTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach(HostedTestSupport.tearDown)
        windows = []
        super.tearDown()
    }

    /// A model on its own notification center, so a test never reacts to the real app becoming active.
    private func makeModel(_ fake: FakeLoginItemService, center: NotificationCenter = NotificationCenter()) -> MacLaunchAtLoginModel {
        MacLaunchAtLoginModel(service: fake, notificationCenter: center)
    }

    // MARK: Default and state

    func testItIsOffByDefaultAndTheModelNeverRegistersOnItsOwn() {
        let fake = FakeLoginItemService(status: .notRegistered)
        let model = makeModel(fake)
        model.refresh()
        XCTAssertFalse(model.isOn)
        XCTAssertFalse(model.showsApprovalHelp)
        XCTAssertFalse(model.showsError)
        XCTAssertEqual(fake.registerCount, 0, "the app never registers itself without the user")
        XCTAssertEqual(fake.unregisterCount, 0)
    }

    func testTheModelReadsTheSystemStatusWhenItIsMade() {
        XCTAssertTrue(makeModel(FakeLoginItemService(status: .enabled)).isOn)
        XCTAssertFalse(makeModel(FakeLoginItemService(status: .notRegistered)).isOn)
    }

    func testTurningOnRegistersAndTurningOffUnregisters() {
        let fake = FakeLoginItemService(status: .notRegistered)
        let model = makeModel(fake)
        model.setOn(true)
        XCTAssertEqual(fake.registerCount, 1)
        XCTAssertTrue(model.isOn)
        XCTAssertFalse(model.showsError)
        model.setOn(false)
        XCTAssertEqual(fake.unregisterCount, 1)
        XCTAssertFalse(model.isOn)
        XCTAssertFalse(model.showsError)
    }

    // MARK: Approval

    func testARegisterThatNeedsApprovalKeepsTheToggleOnAndShowsTheApprovalHelp() {
        let fake = FakeLoginItemService(status: .notRegistered)
        fake.statusAfterRegister = .requiresApproval
        let model = makeModel(fake)
        model.setOn(true)
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isOn, "the request is registered; turning it off must stay possible")
        XCTAssertTrue(model.showsApprovalHelp)
        XCTAssertFalse(model.showsError)
    }

    func testTheOpenButtonOpensLoginItemsInSystemSettings() {
        let fake = FakeLoginItemService(status: .requiresApproval)
        let model = makeModel(fake)
        model.openLoginItemsSettings()
        XCTAssertEqual(fake.openSettingsCount, 1)
        XCTAssertEqual(fake.registerCount, 0, "opening System Settings changes nothing itself")
    }

    func testTurningOffWhileApprovalIsPendingUnregisters() {
        let fake = FakeLoginItemService(status: .requiresApproval)
        let model = makeModel(fake)
        model.setOn(false)
        XCTAssertEqual(fake.unregisterCount, 1)
        XCTAssertFalse(model.isOn)
        XCTAssertFalse(model.showsApprovalHelp)
    }

    // MARK: Errors

    func testARegisterErrorShowsTheErrorAndTheToggleFollowsTheSystem() {
        let fake = FakeLoginItemService(status: .notRegistered)
        fake.registerError = FakeLoginItemService.Refused()
        let model = makeModel(fake)
        model.setOn(true)
        XCTAssertEqual(fake.registerCount, 1)
        XCTAssertFalse(model.isOn, "the system still says not registered")
        XCTAssertTrue(model.showsError)
    }

    func testAnUnregisterErrorShowsTheErrorAndTheToggleStaysOn() {
        let fake = FakeLoginItemService(status: .enabled)
        fake.unregisterError = FakeLoginItemService.Refused()
        let model = makeModel(fake)
        model.setOn(false)
        XCTAssertEqual(fake.unregisterCount, 1)
        XCTAssertTrue(model.isOn, "the system still says enabled")
        XCTAssertTrue(model.showsError)
    }

    func testNotFoundShowsTheErrorWithTheToggleOff() {
        let model = makeModel(FakeLoginItemService(status: .notFound))
        XCTAssertFalse(model.isOn)
        XCTAssertTrue(model.showsError)
        XCTAssertFalse(model.showsApprovalHelp)
    }

    func testAFailedChangeIsClearedByTheNextSuccessfulOne() {
        let fake = FakeLoginItemService(status: .notRegistered)
        fake.registerError = FakeLoginItemService.Refused()
        let model = makeModel(fake)
        model.setOn(true)
        XCTAssertTrue(model.showsError)
        fake.registerError = nil
        model.setOn(true)
        XCTAssertTrue(model.isOn)
        XCTAssertFalse(model.showsError)
    }

    // MARK: Reading the system status again

    func testRefreshFollowsAChangeMadeInSystemSettings() {
        let fake = FakeLoginItemService(status: .requiresApproval)
        let model = makeModel(fake)
        XCTAssertTrue(model.showsApprovalHelp)
        fake.status = .enabled
        model.refresh()
        XCTAssertTrue(model.isOn)
        XCTAssertFalse(model.showsApprovalHelp, "the user allowed it in Login Items")
        fake.status = .notRegistered
        model.refresh()
        XCTAssertFalse(model.isOn, "the user removed it in Login Items")
    }

    func testRefreshDropsAStaleError() {
        let fake = FakeLoginItemService(status: .notRegistered)
        fake.registerError = FakeLoginItemService.Refused()
        let model = makeModel(fake)
        model.setOn(true)
        XCTAssertTrue(model.showsError)
        model.refresh()
        XCTAssertFalse(model.showsError)
        XCTAssertEqual(fake.registerCount, 1, "refresh only reads")
    }

    func testTheAppBecomingActiveReadsTheStatusAgain() {
        let center = NotificationCenter()
        let fake = FakeLoginItemService(status: .requiresApproval)
        let model = makeModel(fake, center: center)
        fake.status = .enabled
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertFalse(model.showsApprovalHelp)
        XCTAssertEqual(fake.registerCount, 0)
    }

    func testAnotherNotificationDoesNotReadTheStatus() {
        let center = NotificationCenter()
        let fake = FakeLoginItemService(status: .notRegistered)
        let model = makeModel(fake, center: center)
        fake.status = .enabled
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(model.status, .notRegistered)
    }

    // MARK: The row

    private func hostRow(_ fake: FakeLoginItemService) throws -> NSWindow {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let model = makeModel(fake)
        let row = MacLaunchAtLoginSettingsRow(model: model).frame(width: 440, height: 220)
        let window = HostedTestSupport.host(row, size: NSSize(width: 440, height: 220))
        windows.append(window)
        return window
    }

    func testTheRowShowsTheToggleAndOnlyShowsTheOpenButtonWhileApprovalIsPending() throws {
        let boostWasOn = AccessibilityTreeBoost.isOn
        defer { AccessibilityTreeBoost.set(boostWasOn) }
        let toggle = AppLocalization.string("Mac.LaunchAtLogin.Toggle")
        let openButton = AppLocalization.string("Mac.LaunchAtLogin.OpenSettings")

        let plain = try hostRow(FakeLoginItemService(status: .notRegistered))
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: plain).contains(toggle) },
                      "labels: \(AccessibilityProbe.labels(in: plain))")
        HostedTestSupport.settle()
        XCTAssertFalse(AccessibilityProbe.labels(in: plain).contains(openButton))

        let fake = FakeLoginItemService(status: .requiresApproval)
        let pending = try hostRow(fake)
        XCTAssertTrue(HostedTestSupport.waitUntil { AccessibilityProbe.labels(in: pending).contains(openButton) },
                      "labels: \(AccessibilityProbe.labels(in: pending))")
        XCTAssertTrue(AccessibilityProbe.press(openButton, in: pending))
        XCTAssertEqual(fake.openSettingsCount, 1)
    }

    // MARK: The real service

    func testTheLiveServiceTouchesNothingUnderXCTest() {
        XCTAssertTrue(MacLiveLoginItemService.isInert,
                      "the test host is the real Conduit app: the live service must not reach SMAppService here")
    }

    // MARK: Sources

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func lines(_ path: String) throws -> [String] {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n")
    }

    /// One file names `SMAppService`, so one place can register the app and the live service stays behind its protocol.
    func testOnlyTheLiveServiceFileNamesSMAppService() throws {
        var users: [String] = []
        for folder in ["Conduit", "Shared", "ConduitMac"] {
            let root = repoRoot.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let item = files?.nextObject() as? URL {
                guard item.pathExtension == "swift" else { continue }
                let text = MacWordingTests.strippingComments(from: try String(contentsOf: item, encoding: .utf8))
                if text.contains("SMAppService") { users.append(String(item.path.dropFirst(repoRoot.path.count + 1))) }
            }
        }
        XCTAssertEqual(users, ["ConduitMac/App/MacLoginItemService.swift"])
    }

    /// The Settings row sits in its own Mac region next to the Spotlight row, tagged with the D-number.
    func testTheSettingsRowIsInItsOwnMacRegionNextToSpotlight() throws {
        let all = try lines("Conduit/Views/AuxiliaryViews.swift")
        let rows = all.indices.filter { all[$0].contains("MacLaunchAtLoginSettingsRow()") }
        XCTAssertEqual(rows.count, 1)
        guard let row = rows.first else { return }
        XCTAssertEqual(all[row - 1].trimmingCharacters(in: .whitespaces), "#if os(macOS) // MAC: launch at login (D28)")
        XCTAssertEqual(all[row + 1].trimmingCharacters(in: .whitespaces), "#endif")
        let spotlight = try XCTUnwrap(all.firstIndex { $0.contains("MacSpotlightSettingsRow()") })
        XCTAssertTrue((1...4).contains(row - spotlight), "the row follows the Spotlight row")
    }

    func testTheLedgerAndTheDecisionLogNameTheFeature() throws {
        let ledger = try lines("docs/macos/PORTING_LEDGER.md").joined(separator: "\n")
        XCTAssertTrue(ledger.contains("MacLaunchAtLoginSettingsRow"), "the AuxiliaryViews edit needs a ledger row")
        let decisions = try lines("docs/macos/DECISIONS.md").joined(separator: "\n")
        XCTAssertTrue(decisions.contains("## D28: Launch at login"))
    }

    // MARK: Catalog

    private func catalogEntry(_ key: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(object?["strings"] as? [String: [String: Any]])
        let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: Any], "\(key) is not in the catalog")
        var result: [String: String] = [:]
        for (language, body) in localizations {
            let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
            result[language] = unit?["value"] as? String
        }
        return result
    }

    func testTheRowTextSaysWhatToDoInEnglish() throws {
        XCTAssertEqual(try catalogEntry("Mac.LaunchAtLogin.Toggle")["en"], "Open Conduit at login")
        let approval = try XCTUnwrap(try catalogEntry("Mac.LaunchAtLogin.RequiresApproval")["en"])
        XCTAssertTrue(approval.contains("Allow Conduit") && approval.contains("Login Items"), approval)
        XCTAssertEqual(try catalogEntry("Mac.LaunchAtLogin.OpenSettings")["en"], "Open Login Items")
        XCTAssertFalse(try XCTUnwrap(try catalogEntry("Mac.LaunchAtLogin.Failed")["en"]).isEmpty)
        let note = try XCTUnwrap(try catalogEntry("Mac.LaunchAtLogin.Note")["en"])
        XCTAssertTrue(note.contains("Quick Ask") && note.contains("only while Conduit is open"), note)
    }

    func testEveryRowKeyResolvesInTheBundle() {
        for key in ["Mac.LaunchAtLogin.Toggle", "Mac.LaunchAtLogin.Note", "Mac.LaunchAtLogin.RequiresApproval",
                    "Mac.LaunchAtLogin.OpenSettings", "Mac.LaunchAtLogin.Failed"] {
            let missing = "\u{1}missing"
            XCTAssertNotEqual(Bundle.main.localizedString(forKey: key, value: missing, table: nil), missing,
                              "\(key) is missing from the compiled catalog")
        }
    }
}
