import XCTest
@testable import ConduitMac

/// A test run must leave nothing behind in the user's Library (final review I1).
/// The test host is the real app, so `UserDefaults.standard` is the user's own domain, and
/// a defaults suite named like a bundle id is a plist in `~/Library/Preferences`.
@MainActor
final class TestDefaultsIsolationTests: XCTestCase {
    private var preferencesFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    /// Every place cfprefsd could keep the plist of a suite: next to a suite named by a path, or
    /// in the Preferences folder (the base name of the suite).
    private func plistLocations(of name: String) -> [URL] {
        var locations = [preferencesFolder.appendingPathComponent((name as NSString).lastPathComponent + ".plist")]
        if name.hasPrefix("/") { locations.append(URL(fileURLWithPath: name + ".plist")) }
        return locations
    }

    private func existingFiles(_ locations: [URL]) -> [URL] {
        locations.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// cfprefsd writes a suite's plist at once, and writes it again after a delay (up to 2.5 s in a
    /// measurement of 150 suites) when something deleted the file. So the check waits before it says
    /// that nothing is left.
    func testADroppedSuiteLeavesNoPlistBehind() {
        let suite = HostedTestSupport.makeSuite()
        suite.defaults.set("value", forKey: "probe")
        let locations = plistLocations(of: suite.name)
        XCTAssertTrue(HostedTestSupport.waitUntil(timeout: 2) { !existingFiles(locations).isEmpty },
                      "control: the plist of a live suite exists, so this test can see a leftover")

        HostedTestSupport.dropSuite(suite)

        let leftover = HostedTestSupport.waitUntil(timeout: 2.5) { !existingFiles(locations).isEmpty }
        let paths = existingFiles(locations).map(\.path)
        // Keep the Preferences folder clean even when the assertion fails.
        defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        XCTAssertFalse(leftover, "a plist is left for \(suite.name): \(paths)")
    }

    /// A test that forgets `dropSuite` does not leave a plist either: the guard removes what is left when the bundle ends.
    func testALeakedSuiteIsRemovedWhenTheBundleEnds() {
        let before = TestDefaultsSuites.liveCount
        let suite = HostedTestSupport.makeSuite()
        suite.defaults.set("value", forKey: "probe")
        let locations = plistLocations(of: suite.name)
        XCTAssertEqual(TestDefaultsSuites.liveCount, before + 1)

        TestDefaultsSuites.removeLeaked()

        XCTAssertEqual(TestDefaultsSuites.liveCount, 0)
        XCTAssertTrue((suite.defaults.persistentDomain(forName: suite.name) ?? [:]).isEmpty, "the domain is cleared")
        XCTAssertFalse(HostedTestSupport.waitUntil(timeout: 0.5) { !existingFiles(locations).isEmpty }, "no plist is left")
    }

    // MARK: Standard domain keys

    func testSnapshotRestoresAStoredValueAndAnAbsence() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.register(defaults: ["absent": true])
        suite.defaults.set(7, forKey: "kept")
        let snapshot = StandardDefaultsSnapshot(keys: ["kept", "absent"], defaults: suite.defaults, domain: suite.name)

        suite.defaults.set(9, forKey: "kept")
        suite.defaults.set(false, forKey: "absent")
        snapshot.restore()

        XCTAssertEqual(suite.defaults.integer(forKey: "kept"), 7)
        XCTAssertNil(suite.defaults.persistentDomain(forName: suite.name)?["absent"],
                     "an absent key stays absent: the registered default is not written back")
        XCTAssertTrue(suite.defaults.bool(forKey: "absent"), "the registered default shows again")
    }

    func testRestoreDoesNotWriteAKeyThatHasItsSavedValue() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        let observer = KeyWriteObserver()
        suite.defaults.set("one", forKey: "watched")
        let snapshot = StandardDefaultsSnapshot(keys: ["watched", "absent"], defaults: suite.defaults, domain: suite.name)
        suite.defaults.addObserver(observer, forKeyPath: "watched", options: [], context: nil)
        suite.defaults.addObserver(observer, forKeyPath: "absent", options: [], context: nil)
        defer {
            suite.defaults.removeObserver(observer, forKeyPath: "watched")
            suite.defaults.removeObserver(observer, forKeyPath: "absent")
        }

        suite.defaults.set("two", forKey: "watched")
        XCTAssertEqual(observer.writes, 1, "control: the observer sees a write")
        snapshot.restore()
        XCTAssertEqual(observer.writes, 2, "the changed key is put back")
        snapshot.restore()
        XCTAssertEqual(observer.writes, 2, "a key that has its saved value, and a key that is still absent, are not written")
        XCTAssertEqual(suite.defaults.string(forKey: "watched"), "one")
    }

    private final class KeyWriteObserver: NSObject {
        var writes = 0
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            writes += 1
        }
    }

    func testSnapshotByPrefixPutsBackSavedFramesAndRemovesNewOnes() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set("1 2 3 4", forKey: "NSWindow Frame conduit-primary-AppWindow-1")
        suite.defaults.set("keep", forKey: "NSWindow Frame SomeoneElse")
        let snapshot = StandardDefaultsSnapshot(prefixes: ["NSWindow Frame conduit-"], defaults: suite.defaults, domain: suite.name)

        suite.defaults.set("5 6 7 8", forKey: "NSWindow Frame conduit-primary-AppWindow-1")
        suite.defaults.set("9 9 9 9", forKey: "NSWindow Frame conduit-session-AppWindow-2")
        suite.defaults.set("changed", forKey: "NSWindow Frame SomeoneElse")
        snapshot.restore()

        XCTAssertEqual(suite.defaults.string(forKey: "NSWindow Frame conduit-primary-AppWindow-1"), "1 2 3 4")
        XCTAssertNil(suite.defaults.string(forKey: "NSWindow Frame conduit-session-AppWindow-2"), "a frame saved since the snapshot is removed")
        XCTAssertEqual(suite.defaults.string(forKey: "NSWindow Frame SomeoneElse"), "changed", "a key with another prefix is not touched")
    }

    func testSnapshotLeavesOtherKeysAlone() {
        let suite = HostedTestSupport.makeSuite()
        defer { HostedTestSupport.dropSuite(suite) }
        suite.defaults.set("one", forKey: "watched")
        suite.defaults.set("two", forKey: "other")
        let snapshot = StandardDefaultsSnapshot(keys: ["watched"], defaults: suite.defaults, domain: suite.name)

        suite.defaults.set("changed", forKey: "watched")
        suite.defaults.set("changed", forKey: "other")
        snapshot.restore()

        XCTAssertEqual(suite.defaults.string(forKey: "watched"), "one")
        XCTAssertEqual(suite.defaults.string(forKey: "other"), "changed")
    }

    // MARK: The bundle-end check

    func testWatchReportsAnOwnedKeyThatWasAddedRemovedOrChanged() {
        let before: [String: Any] = ["conduit.sidebarTab": "Sessions", "conduit.accentChoice": "amber"]
        let after: [String: Any] = ["conduit.sidebarTab": "Kanban", "conduit.useV2Shell": true]
        XCTAssertEqual(RealDefaultsWatch.changes(from: before, to: after), [
            .removed("conduit.accentChoice"), .changed("conduit.sidebarTab"), .added("conduit.useV2Shell")
        ])
    }

    func testWatchIgnoresKeysTheAppDoesNotOwn() {
        let before: [String: Any] = ["NSWindow Frame conduit-primary-AppWindow-1": "1 2 3 4", "SULastCheckTime": "then"]
        let after: [String: Any] = ["NSWindow Frame conduit-primary-AppWindow-1": "5 6 7 8", "SUHasLaunchedBefore": true]
        XCTAssertEqual(RealDefaultsWatch.changes(from: before, to: after), [])
        XCTAssertTrue(RealDefaultsWatch.owns("conduit.mac.sidebarVisible"))
        XCTAssertTrue(RealDefaultsWatch.owns("hermesCalls.ringsLikeCall"))
        XCTAssertFalse(RealDefaultsWatch.owns("NSNavPanelExpandedSizeForOpenMode"))
    }

    func testWatchTreatsEqualDataArraysAndDictionariesAsUnchanged() {
        let value: [String: Any] = [
            "conduit.chatResume.v1": Data([1, 2, 3]),
            "conduit.knownProfiles.v1": ["default", "writer"],
            "conduit.mac.notchStatus.dock.1": ["edge": 2, "offset": 0.75],
        ]
        let same: [String: Any] = [
            "conduit.chatResume.v1": Data([1, 2, 3]),
            "conduit.knownProfiles.v1": ["default", "writer"],
            "conduit.mac.notchStatus.dock.1": ["edge": 2, "offset": 0.75],
        ]
        XCTAssertEqual(RealDefaultsWatch.changes(from: value, to: same), [])
    }

    func testWatchFailsTheTestThatChangedAKeyAndThenMovesOn() {
        var domain: [String: Any] = ["conduit.sidebarTab": "Sessions"]
        let watch = RealDefaultsWatch(read: { domain }, otherConduitIsRunning: { false })
        XCTAssertNil(watch.testFinished("-[QuietTests testNothing]"))

        domain["conduit.sidebarTab"] = "Kanban"
        domain["conduit.useV2Shell"] = true
        let finding = watch.testFinished("-[SomeTests testWritesTheTab]")
        XCTAssertEqual(finding?.isFailure, true)
        let message = finding?.message ?? ""
        XCTAssertTrue(message.contains("-[SomeTests testWritesTheTab] changed the user's real defaults"), message)
        XCTAssertTrue(message.contains("changed conduit.sidebarTab"), message)
        XCTAssertTrue(message.contains("added conduit.useV2Shell"), message)
        XCTAssertFalse(message.contains("another Conduit"), message)

        XCTAssertNil(watch.testFinished("-[LaterTests testNothing]"), "one stray write fails one test, not every test after it")
    }

    func testWatchPassesWhenATestRestoresWhatItChanged() {
        var domain: [String: Any] = ["conduit.sidebarTab": "Sessions"]
        let watch = RealDefaultsWatch(read: { domain }, otherConduitIsRunning: { false })
        domain["conduit.sidebarTab"] = "Kanban"
        domain["conduit.sidebarTab"] = "Sessions"
        XCTAssertNil(watch.testFinished("-[SomeTests testRestores]"))
    }

    /// A running installed Conduit writes the same domain, so a diff proves nothing then: a note, not a failure.
    func testWatchOnlyNotesTheChangeWhileAnotherConduitRuns() {
        var domain: [String: Any] = [:]
        let watch = RealDefaultsWatch(read: { domain }, otherConduitIsRunning: { true })
        domain["conduit.mac.sidebarVisible"] = true
        let finding = watch.testFinished("-[SomeTests testWrites]")
        XCTAssertEqual(finding?.isFailure, false)
        XCTAssertTrue(finding?.message.contains("another Conduit is running") == true, finding?.message ?? "")
        XCTAssertTrue(finding?.message.contains("added conduit.mac.sidebarVisible") == true, finding?.message ?? "")
    }

    // MARK: Shared stores of the host app

    /// The host app binds `MacSessionTabsStore.shared` to its own AppState. A test that opens a chat on that AppState
    /// (`ChatAttachmentDropTests`) made the store save "drop-test-..." tabs into the user's tab strip.
    func testTheSharedTabsStoreSavesOutsideTheUsersDomainUnderTest() {
        XCTAssertFalse(MacSessionTabsStore.shared.defaults === UserDefaults.standard)
    }

    /// Only the helper creates a suite, so only the helper has to clean one up.
    func testNoTestCreatesASuiteOutsideTheHelper() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = "UserDefaults(" + "suiteName:"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if file.lastPathComponent == "TestDefaultsIsolation.swift" { continue }
            if try String(contentsOf: file, encoding: .utf8).contains(needle) { offenders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(offenders.sorted(), [], "use HostedTestSupport.makeSuite() and dropSuite(_:)")
    }
}
