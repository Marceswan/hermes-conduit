//
//  TestDefaultsIsolation.swift
//  ConduitMacTests
//
//  The test host is the real Mac app, so a test that touches UserDefaults can touch the
//  user's own data. Three parts keep it out (final review I1):
//
//  - TestDefaultsSuites: throwaway suites that leave no plist in ~/Library/Preferences.
//  - StandardDefaultsSnapshot: save and restore for the keys of UserDefaults.standard that a
//    test must write because the code under test reads the standard domain.
//  - RealDefaultsWatch: the check, run by MacTestKeychainGuard after every test, that the test left
//    no changed value in the user's domain.
//

import Foundation
import XCTest
@testable import ConduitMac

// MARK: - Suites

/// Defaults suites for tests, kept out of `~/Library/Preferences`.
///
/// A suite with a plain name is a plist in the Preferences folder, and `removePersistentDomain` leaves it
/// there as an empty 50 byte file. Deleting that file does not help: cfprefsd holds the domain and writes it
/// again, up to 2.5 s later and more than once (measured with 150 suites on macOS 27.2: 121 of them came
/// back at least twice). A suite named by an absolute path keeps its plist next to that path instead, and
/// when the folder around the plist is gone, cfprefsd has nowhere to write it again. So each suite gets a
/// folder of its own under the temporary directory, and removing the suite removes the folder.
enum TestDefaultsSuites {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: Set<String> = []

    /// One folder per test process, so a second test run at the same time keeps its own suites.
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit.mac.tests.defaults.\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func make() -> (defaults: UserDefaults, name: String) {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folder.appendingPathComponent("suite").path
        lock.lock()
        live.insert(name)
        lock.unlock()
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Clears the suite's domain and deletes its folder, and with it the plist.
    static func remove(_ name: String, defaults: UserDefaults? = nil) {
        (defaults ?? UserDefaults(suiteName: name))?.removePersistentDomain(forName: name)
        let folder = URL(fileURLWithPath: name).deletingLastPathComponent()
        // Never delete outside this process's own folder.
        if folder.path.hasPrefix(root.path + "/") { try? FileManager.default.removeItem(at: folder) }
        lock.lock()
        live.remove(name)
        lock.unlock()
    }

    /// Removes the suites that no test dropped, and the process folder.
    static func removeLeaked() {
        lock.lock()
        let leaked = live
        lock.unlock()
        leaked.forEach { remove($0) }
        try? FileManager.default.removeItem(at: root)
    }

    /// Suites that were made and not removed.
    static var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }
}

// MARK: - Keys of the standard domain

/// The stored values of some keys in a defaults domain, to put back after a test.
///
/// For a test whose code under test reads `UserDefaults.standard` and takes no injected suite. The snapshot
/// reads the persistent domain, not `object(forKey:)`: that call also returns a registered default, and
/// putting it back would turn "no stored value" into a stored one. `prefixes` name keys that are not known
/// in advance, such as the frame that AppKit saves for a window: every key of the domain that starts with one
/// is put back, and one that appeared since the snapshot is removed.
struct StandardDefaultsSnapshot: @unchecked Sendable {
    private let defaults: UserDefaults
    private let domain: String
    private let stored: [String: Any]
    private let keys: [String]
    private let prefixes: [String]

    init(keys: [String] = [], prefixes: [String] = [], defaults: UserDefaults = .standard,
         domain: String = Bundle.main.bundleIdentifier ?? "") {
        self.defaults = defaults
        self.domain = domain
        self.keys = keys
        self.prefixes = prefixes
        let domainValues = defaults.persistentDomain(forName: domain) ?? [:]
        stored = domainValues.filter { entry in
            keys.contains(entry.key) || prefixes.contains { entry.key.hasPrefix($0) }
        }
    }

    /// Puts each key back. A key that already has its saved value (or is still absent) is not written: a test
    /// that never wrote the key does not touch the user's domain here either.
    func restore() {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        let newKeys = current.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        for key in Set(keys).union(stored.keys).union(newKeys) {
            if let value = stored[key] {
                if (current[key] as AnyObject?)?.isEqual(value) != true { defaults.set(value, forKey: key) }
            } else if current[key] != nil {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

extension XCTestCase {
    /// Restores these keys of `UserDefaults.standard` (value or absence) when the test ends, also when it fails.
    /// Call it before the test writes them, in `setUp` or at the top of the test.
    func preserveStandardDefaults(_ keys: String...) {
        let snapshot = StandardDefaultsSnapshot(keys: keys)
        addTeardownBlock { snapshot.restore() }
    }
}

// MARK: - The check

/// Compares the keys the app owns in the user's real defaults domain after each test with what they were
/// before it.
///
/// MacTestKeychainGuard calls `testFinished` from a teardown block that it adds to every test, so the failure
/// lands on the test that was running. A check in `testBundleDidFinish` cannot do this: XCTest drops a
/// failure recorded there and the run still reports success (measured with Xcode 27.1, with a test that wrote one key).
/// The baseline moves after each test, so one stray write fails one test and not every test after it.
///
/// A running installed Conduit writes the same domain (sidebar tab, accent, open chats, read ledger), and a diff
/// cannot tell its writes from a test's. While another process with this bundle id runs, the outcome is a note
/// and not a failure: the first run of this guard failed a test that only an outside click had touched. Quit
/// Conduit before the run you rely on.
final class RealDefaultsWatch {
    enum Change: Equatable, Comparable {
        case added(String), removed(String), changed(String)

        var key: String {
            switch self {
            case .added(let key), .removed(let key), .changed(let key): return key
            }
        }

        var text: String {
            switch self {
            case .added(let key): return "added \(key)"
            case .removed(let key): return "removed \(key)"
            case .changed(let key): return "changed \(key)"
            }
        }

        static func < (lhs: Change, rhs: Change) -> Bool { lhs.key < rhs.key }
    }

    /// The prefixes of the keys the app writes (`@AppStorage`, `MacDefaults` and the stores). The keys of
    /// AppKit, Sparkle and the system, such as window frames, are not the app's own.
    static let ownedPrefixes = [
        "conduit.", "Conduit", "hermes", "richCards.", "watchDirect.", "artifacts.", "capabilities.", "voice.", "share."
    ]

    static func owns(_ key: String) -> Bool {
        ownedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The owned keys of the user's persistent domain.
    static func readRealDomain() -> [String: Any] {
        let domain = Bundle.main.bundleIdentifier ?? ""
        return (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { owns($0.key) }
    }

    /// The keys that AppKit writes for the host's own windows. A test that resizes or moves the host's main window
    /// changes the frame that the user's Conduit opens with, so the guard puts these back when the bundle ends.
    static let appKitWindowKeyPrefixes = ["NSWindow Frame conduit-", "NSSplitView Subview Frames conduit-"]

    /// Whether a second process with this app's bundle id runs.
    static func anotherConduitIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    static func changes(from before: [String: Any], to after: [String: Any]) -> [Change] {
        var result: [Change] = []
        for (key, value) in before where owns(key) {
            guard let now = after[key] else { result.append(.removed(key)); continue }
            if !(value as AnyObject).isEqual(now) { result.append(.changed(key)) }
        }
        for key in after.keys where owns(key) && before[key] == nil { result.append(.added(key)) }
        return result.sorted()
    }

    private let read: () -> [String: Any]
    private let otherConduitIsRunning: () -> Bool
    private var baseline: [String: Any]
    private let lock = NSLock()

    /// Takes the first reading now.
    init(read: @escaping () -> [String: Any] = RealDefaultsWatch.readRealDomain,
         otherConduitIsRunning: @escaping () -> Bool = RealDefaultsWatch.anotherConduitIsRunning) {
        self.read = read
        self.otherConduitIsRunning = otherConduitIsRunning
        baseline = read()
    }

    /// What the guard found after a test.
    struct Finding: Equatable {
        /// Whether it fails the test. It does not while another Conduit runs.
        var isFailure: Bool
        var message: String
    }

    /// The finding for the test that just ended, or nil when every owned key has the value it had after the
    /// test before. Writes that came between two tests, from async work of an earlier test or from another
    /// process, land on the test that ends next.
    func testFinished(_ name: String) -> Finding? {
        let now = read()
        lock.lock()
        let found = Self.changes(from: baseline, to: now)
        baseline = now
        lock.unlock()
        guard !found.isEmpty else { return nil }
        let id = Bundle.main.bundleIdentifier ?? "?"
        let concurrent = otherConduitIsRunning()
        var lines = concurrent
            ? ["note (not a failure): another Conduit is running and writes the same defaults, so these changes may be its own. After \(name) the user's real defaults (\(id)) differ:"]
            : ["\(name) changed the user's real defaults (\(id)), during it or just before it:"]
        lines += found.map { "  \($0.text)" }
        lines.append(concurrent
            ? "Quit Conduit and run the test again to check."
            : "A test must use HostedTestSupport.makeSuite() or preserveStandardDefaults(_:).")
        return Finding(isFailure: !concurrent, message: lines.joined(separator: "\n"))
    }
}
