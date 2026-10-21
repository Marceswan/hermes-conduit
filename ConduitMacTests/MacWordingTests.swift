import XCTest
@testable import ConduitMac

/// Task 9b: text that upstream wrote for the iPhone reads as Mac text on the Mac.
///
/// Two kinds of change are pinned here, both by reading the source (the views are upstream's, compiled
/// into the Mac app, and most of the text sits in screens that need a live Hermes host):
/// - a gate: an iPhone-only Settings section sits in `#if !os(macOS) // MAC:` (ledger: Kept off on Mac);
/// - a Mac region: `#if os(macOS) // MAC:` holds the Mac wording, `#else // MAC:` keeps upstream's text.
/// The catalog test checks every new key: all languages, no "iPhone".
final class MacWordingTests: XCTestCase {
    private let languages = ["de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Source helpers

    private func lines(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let url = repoRoot.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// Every line that holds `needle`.
    private func indices(of needle: String, in lines: [String]) -> [Int] {
        lines.indices.filter { lines[$0].contains(needle) }
    }

    /// The nearest preprocessor line at or above `index`, with its line number.
    private func directive(above index: Int, in lines: [String]) -> (line: Int, text: String)? {
        var at = index
        while at >= 0 {
            let text = trimmed(lines[at])
            if text.hasPrefix("#if") || text.hasPrefix("#else") || text.hasPrefix("#endif") { return (at, text) }
            at -= 1
        }
        return nil
    }

    /// The first `#else` or `#endif` below `index`.
    private func nextBranch(below index: Int, in lines: [String]) -> (line: Int, text: String)? {
        var at = index
        while at < lines.count {
            let text = trimmed(lines[at])
            if text.hasPrefix("#else") || text.hasPrefix("#endif") { return (at, text) }
            at += 1
        }
        return nil
    }

    /// The Mac needle sits between `#if os(macOS) // MAC:` and `#else // MAC:`; upstream's text sits
    /// between that `#else // MAC:` and `#endif // MAC:`. Checked at every site of the Mac needle.
    private func assertMacRegion(
        _ path: String, mac: String, upstream: String, sites: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let all = try lines(path)
        let found = indices(of: mac, in: all)
        XCTAssertEqual(found.count, sites, "\(path): sites of \(mac)", file: file, line: line)
        for at in found {
            guard let open = directive(above: at, in: all), open.text.hasPrefix("#if os(macOS) // MAC:") else {
                XCTFail("\(path):\(at + 1): \(mac) is not directly under `#if os(macOS) // MAC:`", file: file, line: line)
                continue
            }
            guard let otherwise = nextBranch(below: at, in: all), otherwise.text == "#else // MAC:" else {
                XCTFail("\(path):\(at + 1): no `#else // MAC:` after \(mac)", file: file, line: line)
                continue
            }
            guard let close = nextBranch(below: otherwise.line + 1, in: all), close.text == "#endif // MAC:" else {
                XCTFail("\(path):\(at + 1): no `#endif // MAC:` after the `#else // MAC:`", file: file, line: line)
                continue
            }
            let macBranch = all[(open.line + 1)..<otherwise.line].joined(separator: "\n")
            let upstreamBranch = all[(otherwise.line + 1)..<close.line].joined(separator: "\n")
            XCTAssertTrue(upstreamBranch.contains(upstream),
                          "\(path):\(at + 1): upstream's text is missing from the #else branch: \(upstream)", file: file, line: line)
            XCTAssertFalse(macBranch.contains(upstream),
                           "\(path):\(at + 1): the Mac branch still holds upstream's text", file: file, line: line)
        }
    }

    /// `first` sits directly under `#if !os(macOS) // MAC:`, the region ends in `#endif // MAC:` with no
    /// `#else` (the Mac gets nothing), every `inside` needle is in the region and every `outside` needle is not.
    private func assertGated(
        _ path: String, first: String, inside: [String] = [], outside: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let all = try lines(path)
        let starts = indices(of: first, in: all)
        XCTAssertEqual(starts.count, 1, "\(path): sites of \(first)", file: file, line: line)
        guard let at = starts.first else { return }
        guard let open = directive(above: at, in: all), open.text.hasPrefix("#if !os(macOS) // MAC:") else {
            XCTFail("\(path):\(at + 1): \(first) is not directly under `#if !os(macOS) // MAC:`", file: file, line: line)
            return
        }
        guard let close = nextBranch(below: at, in: all), close.text == "#endif // MAC:" else {
            XCTFail("\(path):\(at + 1): the gate does not end in `#endif // MAC:` (an `#else` would give the Mac a branch)",
                    file: file, line: line)
            return
        }
        let region = all[open.line...close.line].joined(separator: "\n")
        for needle in inside {
            XCTAssertTrue(region.contains(needle), "\(path): the gate at line \(open.line + 1) should hold \(needle)", file: file, line: line)
        }
        for needle in outside {
            XCTAssertFalse(region.contains(needle), "\(path): the gate at line \(open.line + 1) must not hold \(needle)", file: file, line: line)
        }
    }

    // MARK: Gates (iPhone-only features, Kept off on Mac)

    func testCarPlayAndWatchSettingsSectionsAreGatedOffOnMac() throws {
        try assertGated("Conduit/Views/VoiceSettingsView.swift", first: "CarPlaySettingsSection()",
                        inside: ["WatchSettingsSection()"], outside: ["readAloudSection", "wakeSection\n"])
    }

    func testAskHermesAboutScreenSettingsLinksAreGatedOffOnMac() throws {
        try assertGated("Conduit/Views/AuxiliaryViews.swift", first: "settingsLink(.screenQuestion")
        try assertGated("Conduit/Views/AuxiliaryViews.swift", first: "v2Link(.screenQuestion")
    }

    func testAppIconSectionIsGatedOffOnMac() throws {
        try assertGated("Conduit/Views/AuxiliaryViews.swift", first: "ConduitSettingsSection(title: AppLocalization.string(\"App icon\")",
                        inside: ["Choose the icon shown on your Home Screen.", ".accessibilityLabel(\"Use \\(choice.title.lowercased()) app icon\")"],
                        outside: ["Main button"])
    }

    func testListenOnCarPlayWakeToggleIsGatedOffOnMac() throws {
        try assertGated("Conduit/Views/VoiceSettingsView.swift", first: "Toggle(\"Listen on CarPlay\"",
                        inside: [".accessibilityHint(Text(\"On CarPlay, wake listens", "Text(\"On CarPlay, wake listens"],
                        outside: ["Listen while other audio plays"])
    }

    func testSiriLockScreenNoteIsGatedOffOnMac() throws {
        try assertGated("Conduit/Views/VoiceSettingsView.swift", first: "Siri remains the supported way to begin a voice conversation from the Lock Screen.",
                        inside: [".foregroundStyle(.secondary)"])
    }

    func testPushSectionsOfNotificationsSettingsAreGatedOffOnMac() throws {
        let path = "Conduit/Views/AuxiliaryViews.swift"
        // The Mac keeps its own local controls (D20): `MacNotificationSettingsView` stays above the gates.
        let all = try lines(path)
        let local = try XCTUnwrap(indices(of: "MacNotificationSettingsView()", in: all).first)
        XCTAssertEqual(directive(above: local, in: all)?.text.prefix(21), "#if os(macOS) // MAC:")
        try assertGated(path, first: "ConduitSettingsSection(title: AppLocalization.string(\"This iPhone\")",
                        inside: ["SettingsMetricRow(", "notifications.lastError", "\"Enable notifications\""],
                        outside: ["MacNotificationSettingsView()", "\"Notify me when\"", "\"Push relay\""])
        try assertGated(path, first: "ConduitSettingsSection(title: AppLocalization.string(\"Notify me when\")",
                        inside: ["if notifications.isEnabled {", "\"Connect a Hermes profile\"", "\"Verify pairing\"",
                                 "\"Push relay\"", "notifications.relayNotice"],
                        outside: ["MacNotificationSettingsView()", "\"This iPhone\""])
        // The page's refresh reads the relay's metadata: the Mac calls no relay.
        let title = try XCTUnwrap(indices(of: ".navigationTitle(\"Notifications\")", in: all).first)
        XCTAssertTrue(trimmed(all[title + 1]).hasPrefix("#if !os(macOS) // MAC:"), "the refresh task is under a gate")
        let close = try XCTUnwrap(nextBranch(below: title + 2, in: all))
        XCTAssertEqual(close.text, "#endif // MAC:")
        let task = all[(title + 2)..<close.line].joined(separator: "\n")
        XCTAssertTrue(task.contains(".task {") && task.contains("await notifications.refreshMeta()"))
    }

    func testCallsFromHermesEntryPointsAreGatedOffOnMac() throws {
        let path = "Conduit/Views/AuxiliaryViews.swift"
        try assertGated(path, first: "settingsLink(.hermesCalls", inside: ["if appState.supportsHermesCalls {"],
                        outside: ["settingsLink(.workspace", "settingsLink(.voice"])
        try assertGated(path, first: "v2Link(.hermesCalls", inside: ["if appState.supportsHermesCalls {"],
                        outside: ["v2Link(.voice", "v2Group(AppLocalization.string(\"Hermes\")"])
        // A `conduit://settings/calls` link opens Settings at its start on Mac, in both settings hosts.
        try assertMacRegion("Conduit/Views/RootView.swift", mac: "case .calls: settingsOpensAt = nil",
                            upstream: "case .calls: settingsOpensAt = appState.supportsHermesCalls ? page : nil")
        try assertMacRegion("Conduit/Views/V2/V2SettingsTab.swift", mac: "case .calls: fresh.opensAt = nil",
                            upstream: "case .calls: fresh.opensAt = appState.supportsHermesCalls ? page : nil")
    }

    func testNoMacRowReachesTheCallsPage() throws {
        // The only `.hermesCalls` links are the two gated rows; the page destination is reached only through them
        // and through `SettingsDestination(.calls)`, which the two link hosts no longer pass on Mac.
        let all = try lines("Conduit/Views/AuxiliaryViews.swift")
        let links = indices(of: "(.hermesCalls", in: all)
        XCTAssertEqual(links.count, 2, "settingsLink and v2Link are the only rows to the page")
        for at in links {
            XCTAssertEqual(directive(above: at, in: all)?.text.prefix(22), "#if !os(macOS) // MAC:", "line \(at + 1)")
        }
    }

    func testEveryGateHasAKeptOffRow() throws {
        let ledger = try String(contentsOf: repoRoot.appendingPathComponent("docs/macos/PORTING_LEDGER.md"), encoding: .utf8)
        let section = try XCTUnwrap(ledger.components(separatedBy: "## Kept off on Mac").dropFirst().first?
            .components(separatedBy: "## Sync routine").first, "the Kept off on Mac section")
        let rows = section.components(separatedBy: "\n").filter { $0.hasPrefix("| Conduit/") }
        for path in [
            "Conduit/Views/VoiceSettingsView.swift (CarPlaySettingsSection)",
            "Conduit/Views/VoiceSettingsView.swift (WatchSettingsSection)",
            "Conduit/Views/VoiceSettingsView.swift (WakePhraseSettingsSection, Listen on CarPlay)",
            "Conduit/Views/VoiceSettingsView.swift (WakePhraseSettingsSection, Siri Lock Screen note)",
            "Conduit/Views/AuxiliaryViews.swift (Ask Hermes About Screen links)",
            "Conduit/Views/AuxiliaryViews.swift (Appearance, App icon)",
            "Conduit/Views/AuxiliaryViews.swift (NotificationsSettingsDetail, This iPhone push section)",
            "Conduit/Views/AuxiliaryViews.swift (NotificationsSettingsDetail, relay pairing blocks, Push relay section, relay refresh)",
            "Conduit/Views/AuxiliaryViews.swift (Calls from Hermes rows), Conduit/Views/RootView.swift and Conduit/Views/V2/V2SettingsTab.swift (settings links to calls)",
        ] {
            let row = rows.first { $0.hasPrefix("| \(path) |") }
            XCTAssertNotNil(row, "Kept off row: \(path)")
            XCTAssertTrue(row?.contains("// MAC:") == true && (row?.contains("#if !os(macOS)") == true || row?.contains("#if os(macOS)") == true),
                          "gate named: \(path)")
        }
        XCTAssertTrue(rows.filter { $0.contains("iPhone-only feature") }.count >= 5, "the reason is named")
        XCTAssertEqual(rows.filter { $0.contains("needs push (APNs); the Mac uses local notifications only (D20)") }.count, 3,
                       "the push gates name their reason")
    }

    // MARK: Mac regions (device and gesture words)

    func testPermissionTextNamesSystemSettingsOnMac() throws {
        try assertMacRegion("Conduit/Voice/VoiceTypes.swift", mac: "\"Mac.VoiceAudioError.MicrophoneDenied\"",
                            upstream: "Allow it in iPhone Settings > Conduit.")
        try assertMacRegion("Conduit/Views/VoiceSettingsView.swift", mac: "\"Mac.VoiceSettings.MicrophoneDenied\"",
                            upstream: "Allow the microphone for Conduit in iPhone Settings.")
        try assertMacRegion("Conduit/Views/VoiceSettingsView.swift", mac: "\"Mac.VoiceSettings.SpeechRecognitionDenied\"",
                            upstream: "Allow it for Conduit in iPhone Settings, or choose a Hermes provider")
        try assertMacRegion("Conduit/Voice/VoiceSetupIssue.swift", mac: "\"Mac.VoiceSetupIssue.SpeechRecognitionDenied\"",
                            upstream: "Allow Speech Recognition for Conduit in iPhone Settings > Conduit")
        try assertMacRegion("Conduit/Views/VoiceSettingsView.swift", mac: "\"Mac.VoiceSettings.SpeechRecognitionRetry\"",
                            upstream: "Enable Speech Recognition in Settings > Conduit > Speech Recognition", sites: 2)
        try assertMacRegion("Conduit/Cards/RichInfoCardViews.swift", mac: "\"Mac.RichInfoCard.NotificationsOff\"",
                            upstream: "Notifications are off for Conduit in iPhone Settings.")
    }

    func testVoiceSettingsNamesTheMacNotTheIPhone() throws {
        let path = "Conduit/Views/VoiceSettingsView.swift"
        try assertMacRegion(path, mac: "Voice is on for \\(profileDisplayName) on this Mac.", upstream: "on this iPhone. Each step below")
        try assertMacRegion(path, mac: "and uses this Mac to hear you and to speak the replies.", upstream: "and uses this iPhone to hear you")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.SpeechNotAllowedYet\"", upstream: "On this iPhone. Speech Recognition isn't allowed yet.")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.SpeechUnsupportedLanguage\"", upstream: "This iPhone can't transcribe your language")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.UseThisMac\"", upstream: "\"Use this iPhone\"", sites: 2)
        try assertMacRegion(path, mac: "This Mac can do it instead, with nothing to install.", upstream: "This iPhone can do it instead")
        try assertMacRegion(path, mac: "This Mac can speak the replies instead, with nothing to set up.", upstream: "This iPhone can speak the replies instead")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.SystemVoiceDetail\"", upstream: "built into iOS, on this iPhone")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.EnhancedVoices\"", upstream: "download an Enhanced or Premium voice in iPhone Settings")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.AppleSpeechPrivacy\"", upstream: "Captured audio stays on this iPhone.")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.LocalWhisperNote\"", upstream: "not on this iPhone.")
        try assertMacRegion(path, mac: "\"Mac.WakePhrase.ListensOnThisMac\"", upstream: "Listening runs on this iPhone")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.KeepScreenAwakeNote\"", upstream: "the phone locks on its usual timer")
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.OrbMotionNote\"", upstream: "Turn this off for a still orb that uses less battery.", sites: 2)
        try assertMacRegion(path, mac: "\"Mac.VoiceSettings.SaveNowBlocked\"", upstream: "then tap Save Now.")
    }

    func testOnThisMacUsesTheExistingKeyOnMac() throws {
        let all = try lines("Conduit/Views/VoiceSettingsView.swift")
        let macSites = indices(of: "AppLocalization.string(\"On this Mac\")", in: all)
        XCTAssertEqual(macSites.count, 4, "the four 'On this iPhone' labels")
        for at in macSites {
            XCTAssertEqual(directive(above: at, in: all)?.text.prefix(21), "#if os(macOS) // MAC:", "line \(at + 1)")
            let branch = try XCTUnwrap(nextBranch(below: at, in: all), "line \(at + 1)")
            XCTAssertEqual(branch.text, "#else // MAC:", "line \(at + 1)")
            XCTAssertTrue(all[branch.line..<(try XCTUnwrap(nextBranch(below: branch.line + 1, in: all)).line)]
                .joined().contains("On this iPhone"), "line \(at + 1): upstream's label stays in #else")
        }
    }

    func testTimeZoneShortcutNamesTheMac() throws {
        try assertMacRegion("Conduit/Views/AuxiliaryViews.swift", mac: "Use this Mac's time zone (\\(id))",
                            upstream: "Use this iPhone's time zone (\\(id))")
    }

    func testGesturesNameTheMouseOnMac() throws {
        try assertMacRegion("Conduit/Views/AuxiliaryViews.swift", mac: "Text(\"Mac.Chat.SendButtonHint\")",
                            upstream: "Touch and hold the send button to choose another way for one message.")
        try assertMacRegion("Conduit/Services/HermesClient.swift", mac: "\"Mac.HermesClient.QueueUnsupported\"",
                            upstream: "touch and hold send to steer or interrupt instead")
        let sidebar = "Conduit/Views/SidebarView.swift"
        try assertMacRegion(sidebar, mac: "\"Mac.Sidebar.ProjectRowHint\"", upstream: "Swipe or touch and hold to rename or delete it.")
        try assertMacRegion(sidebar, mac: "\"Mac.Sidebar.SessionRowHint\"", upstream: "Swipe or touch and hold for conversation actions.", sites: 3)
        try assertMacRegion("Conduit/Views/MinimisedLiveVoiceBar.swift", mac: "\"Mac.LiveVoiceBar.CallStopped\"",
                            upstream: "Call stopped. Tap to see why.", sites: 2)
        try assertMacRegion("Conduit/Views/ModelPickerView.swift", mac: "\"Mac.ModelPicker.AllHidden\"",
                            upstream: "All providers are hidden. Tap Edit to restore one.")
        try assertMacRegion("Shared/GeminiLive/GeminiLiveSession.swift", mac: "MacSharedWording.geminiLiveResumptionLost",
                            upstream: "Tap Try again to start a new one.")
        try assertMacRegion("Conduit/Views/LiveVoiceSetupSheet.swift", mac: "and click \\(mode.checkTitle) to check availability.",
                            upstream: "and tap \\(mode.checkTitle) to check availability.")
        try assertMacRegion("Conduit/Voice/VoiceConversationController.swift", mac: "\"Mac.VoiceConversation.ListeningStoppedLocked\"",
                            upstream: "Listening stopped while your phone was locked. Tap Listen to continue.")
    }

    func testLiveVoiceAndDictationTextNamesTheMac() throws {
        try assertMacRegion("Conduit/Voice/VoiceSetupIssue.swift", mac: "Allow it in Conduit on your Mac to start the call.",
                            upstream: "Allow it in Conduit on your iPhone to start the call.")
        try assertMacRegion("Conduit/Voice/DictationEngine.swift", mac: "\"Mac.Dictation.AppleSummary\"", upstream: "on this iPhone when your language allows")
        try assertMacRegion("Conduit/Voice/DictationEngine.swift", mac: "\"Mac.Dictation.SpeechAnalyzerSummary\"", upstream: "Apple's newer speech model, on this iPhone.")
        try assertMacRegion("Conduit/Voice/DictationRecognizers.swift", mac: "\"Mac.Dictation.SpeechAnalyzerUnavailable\"",
                            upstream: "isn't available on this iPhone.")
    }

    // MARK: Catalog

    private func strings() throws -> [String: [String: Any]] {
        let url = repoRoot.appendingPathComponent("Conduit/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(object?["strings"] as? [String: [String: Any]])
    }

    private func values(_ entry: [String: Any]?) throws -> [String: (state: String?, value: String?)] {
        let localizations = try XCTUnwrap(entry?["localizations"] as? [String: Any])
        var result: [String: (state: String?, value: String?)] = [:]
        for (language, body) in localizations {
            let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
            result[language] = (unit?["state"] as? String, unit?["value"] as? String)
        }
        return result
    }

    /// Every `Mac.` key this task adds; the two older ones are `Mac.Pane.Home` and `Mac.LiveVoiceConsent.TakeBackHint`.
    private let macKeys = [
        "Mac.VoiceAudioError.MicrophoneDenied", "Mac.VoiceSettings.MicrophoneDenied",
        "Mac.VoiceSettings.SpeechRecognitionDenied", "Mac.VoiceSetupIssue.SpeechRecognitionDenied",
        "Mac.VoiceSettings.SpeechRecognitionRetry", "Mac.RichInfoCard.NotificationsOff",
        "Mac.VoiceSettings.UseThisMac", "Mac.VoiceSettings.SpeechNotAllowedYet", "Mac.VoiceSettings.SpeechUnsupportedLanguage",
        "Mac.VoiceSettings.AppleSpeechPrivacy", "Mac.VoiceSettings.LocalWhisperNote", "Mac.WakePhrase.ListensOnThisMac",
        "Mac.Dictation.AppleSummary", "Mac.Dictation.SpeechAnalyzerSummary", "Mac.Dictation.SpeechAnalyzerUnavailable",
        "Mac.VoiceSettings.SystemVoiceDetail", "Mac.VoiceSettings.EnhancedVoices", "Mac.VoiceSettings.KeepScreenAwakeNote",
        "Mac.VoiceSettings.OrbMotionNote", "Mac.Chat.SendButtonHint", "Mac.HermesClient.QueueUnsupported",
        "Mac.Sidebar.ProjectRowHint", "Mac.Sidebar.SessionRowHint", "Mac.LiveVoiceBar.CallStopped", "Mac.ModelPicker.AllHidden",
        "Mac.GeminiLive.ResumptionLost", "Mac.VoiceSettings.SaveNowBlocked", "Mac.VoiceConversation.ListeningStoppedLocked",
    ]

    /// New keys whose English text is the key (they carry a placeholder, so a symbolic name cannot hold it).
    private let textKeys = [
        "Voice is on for %@ on this Mac. Each step below turns green when it's ready; an orange step has a fix.",
        "Turn this on to talk to %@. Conduit asks for the microphone and Speech Recognition, and uses this Mac to hear you and to speak the replies. Nothing to set up on Hermes.",
        "Use this Mac's time zone (%@)",
        "%@ on Hermes isn't ready (%@). This Mac can do it instead, with nothing to install.",
        "%@ isn't ready on Hermes. This Mac can speak the replies instead, with nothing to set up.",
        "%@ sends your voice to %@. Allow it in Conduit on your Mac to start the call.",
        "Return to Voice settings, enable this mode if it is off, and click %@ to check availability.",
    ]

    func testEveryMacKeyHasEnglishAndAllLanguagesAndNoIPhone() throws {
        let all = try strings()
        let present = Set(all.keys.filter { $0.hasPrefix("Mac.") })
        XCTAssertEqual(present, Set(macKeys + ["Mac.Pane.Home", "Mac.LiveVoiceConsent.TakeBackHint"]),
                       "a Mac. key outside this list, or one of the list missing")
        for key in present.sorted() {
            let v = try values(all[key])
            XCTAssertEqual(Set(v.keys), Set(languages + ["en"]), key)
            for (language, unit) in v {
                XCTAssertEqual(unit.state, "translated", "\(key) [\(language)]")
                let value = unit.value ?? ""
                XCTAssertFalse(value.isEmpty, "\(key) [\(language)] is empty")
                XCTAssertFalse(value.contains("iPhone"), "\(key) [\(language)]: \(value)")
                if language != "en", key != "Mac.Pane.Home" {
                    XCTAssertNotEqual(value, v["en"]?.value, "\(key) [\(language)] is not translated")
                }
            }
        }
    }

    func testTextKeysHaveAllLanguagesAndNoIPhone() throws {
        let all = try strings()
        for key in textKeys {
            XCTAssertFalse(key.contains("iPhone"), key)
            let v = try values(all[key])
            XCTAssertEqual(Set(v.keys), Set(languages), "\(key): the English text is the key, so no `en` value")
            let wanted = key.components(separatedBy: "%@").count - 1
            for (language, unit) in v {
                XCTAssertEqual(unit.state, "translated", "\(key) [\(language)]")
                let value = unit.value ?? ""
                XCTAssertFalse(value.contains("iPhone"), "\(key) [\(language)]: \(value)")
                let found = value.components(separatedBy: "@").count - 1
                XCTAssertEqual(found, wanted, "\(key) [\(language)]: placeholders")
            }
        }
    }

    func testMacKeysResolveInTheBundle() {
        for key in macKeys {
            let missing = "\u{1}missing"
            XCTAssertNotEqual(Bundle.main.localizedString(forKey: key, value: missing, table: nil), missing,
                              "\(key) is missing from the compiled catalog")
        }
    }
}
