import AppKit
import PDFKit
import XCTest
@testable import ConduitMac

/// File > Export Chat... and Print Chat... (D32). The Markdown builder and the file name maker are pure, so
/// fixtures pin them. The panels and the print operation sit behind seams, so no test shows one.
final class MacChatExportBuilderTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-28 14:05:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_196_300)

    static let english = MacChatExportStrings(
        you: "You", fallbackTitle: "Conversation",
        exported: { "Exported \($0)" },
        olderNotIncluded: "Older messages are not included in this export.",
        toolLine: { "Tool: \($0) (\($1))" },
        toolRunning: "running", toolComplete: "complete",
        attachment: { "Attachment: \($0)" })

    private func markdown(
        _ messages: [ChatMessage], title: String? = "Lisbon trip", agent: String = "Hermes", older: Bool = false
    ) -> String {
        MacChatExport.markdown(
            MacChatExportInput(title: title, agentName: agent, messages: messages, olderMessagesOmitted: older),
            exportedAt: now, strings: Self.english, timeZone: utc)
    }

    private func user(_ text: String, at stamp: String = "2026-10-28T14:00:00Z", attachments: [Attachment]? = nil) -> ChatMessage {
        ChatMessage(id: "u-\(text.hashValue)", role: .user, content: text, timestamp: stamp, attachments: attachments)
    }

    private func assistant(_ text: String, at stamp: String = "2026-10-28T14:01:00Z", code: String? = nil,
                           reasoning: String? = nil, role: MessageRole = .assistant) -> ChatMessage {
        ChatMessage(id: "a-\(text.hashValue)", role: role, content: text, timestamp: stamp, reasoning: reasoning, code: code)
    }

    private func tool(_ name: String, _ status: ToolActivity.Status) -> ChatMessage {
        ChatMessage(id: "t-\(name)", role: .tool, content: "", timestamp: "2026-10-28T14:02:00Z",
                    tool: ToolActivity(id: nil, name: name, input: "SECRET-INPUT", output: "SECRET-OUTPUT", status: status))
    }

    // MARK: Layout

    func testTheDocumentHasTheTitleTheExportDateAndEveryMessageInOrder() {
        let text = markdown([
            user("Plan a trip to Lisbon", attachments: [
                Attachment(id: "f1", name: "map.pdf", uri: "file:///tmp/map.pdf", mimeType: "application/pdf", kind: .document),
            ]),
            assistant("Sure.\n\n- Day 1: Alfama\n- Day 2: Belem", reasoning: "SECRET-THINKING"),
            tool("web_search", .complete),
            tool("read_file", .running),
            assistant("Done.", at: "2026-10-28T14:03:00Z"),
        ])
        XCTAssertEqual(text, """
        # Lisbon trip

        Exported 2026-10-28 14:05

        ## You (2026-10-28 14:00)

        Plan a trip to Lisbon

        Attachment: `map.pdf`

        ## Hermes (2026-10-28 14:01)

        Sure.

        - Day 1: Alfama
        - Day 2: Belem

        Tool: `web_search` (complete)\\
        Tool: `read_file` (running)

        ## Hermes (2026-10-28 14:03)

        Done.

        """)
    }

    func testTheSpeakerOfAnAgentRowIsTheBotNameOrHermes() {
        XCTAssertTrue(markdown([assistant("Hi")], agent: "Scout").contains("## Scout (2026-10-28 14:01)"))
        XCTAssertTrue(markdown([assistant("Hi")], agent: "  \n ").contains("## Hermes (2026-10-28 14:01)"))
    }

    func testAStreamingPartialRowReadsAsAnAgentRow() {
        XCTAssertTrue(markdown([assistant("Half an ans", role: .partial)]).contains("## Hermes (2026-10-28 14:01)\n\nHalf an ans\n"))
    }

    func testARowWithoutAKnownTimeHasNoTimeInItsHeading() {
        let text = markdown([user("a", at: ""), user("b", at: "yesterday\n# Evil"), user("c", at: "not a time")])
        XCTAssertEqual(text.components(separatedBy: "## You\n").count - 1, 3, text)
        XCTAssertFalse(text.contains("Evil"), "an unreadable time string is data from the host, not text for the file")
    }

    func testAnEpochTimestampIsRead() {
        XCTAssertTrue(markdown([user("a", at: "1793196000")]).contains("## You (2026-10-28 14:00)"))
    }

    func testTheTimeUsesTheGivenTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let text = MacChatExport.markdown(
            MacChatExportInput(title: "T", agentName: "Hermes", messages: [user("a")], olderMessagesOmitted: false),
            exportedAt: now, strings: Self.english, timeZone: tokyo)
        XCTAssertTrue(text.contains("## You (2026-10-28 23:00)"), text)
        XCTAssertTrue(text.contains("Exported 2026-10-28 23:05"), text)
    }

    func testTheOlderMessagesLineSitsUnderTheTitleOnlyWhenOlderMessagesAreMissing() {
        let with = markdown([user("a")], older: true)
        XCTAssertTrue(with.hasPrefix("# Lisbon trip\n\nExported 2026-10-28 14:05\n\nOlder messages are not included in this export.\n\n## You"), with)
        XCTAssertFalse(markdown([user("a")]).contains("Older messages"))
    }

    func testAnEmptyChatStillHasATitleAndADate() {
        XCTAssertEqual(markdown([]), "# Lisbon trip\n\nExported 2026-10-28 14:05\n")
    }

    func testTheOutputEndsWithOneNewlineAndHasNoCarriageReturn() {
        let text = markdown([user("one\r\ntwo\rthree\n\n\n")])
        XCTAssertTrue(text.hasSuffix("three\n"), text)
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("\r"))
    }

    // MARK: What is left out

    func testThinkingTextIsNeverIncluded() {
        let text = markdown([
            assistant("Answer", reasoning: "SECRET-THINKING"),
            ChatMessage(id: "r1", role: .reasoning, content: "SECRET-REASONING-ROW", timestamp: "2026-10-28T14:01:30Z"),
        ])
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(text.contains("Answer"))
    }

    func testToolInputAndOutputAreNotIncluded() {
        XCTAssertFalse(markdown([tool("grep", .complete)]).contains("SECRET"))
    }

    func testSystemRowsAndCardsAreLeftOut() {
        let text = markdown([
            ChatMessage(id: "s", role: .system, content: "SYSTEM-NOTICE", timestamp: ""),
            ChatMessage(id: "ap", role: .approval, content: "APPROVAL-CARD", timestamp: ""),
            ChatMessage(id: "cl", role: .clarify, content: "CLARIFY-CARD", timestamp: ""),
            ChatMessage(id: "ip", role: .inputPrompt, content: "PASSWORD-PROMPT", timestamp: ""),
            user("kept"),
        ])
        for left in ["SYSTEM-NOTICE", "APPROVAL-CARD", "CLARIFY-CARD", "PASSWORD-PROMPT"] { XCTAssertFalse(text.contains(left), left) }
        XCTAssertTrue(text.contains("kept"))
    }

    func testARowWithNoTextAndNoAttachmentIsSkippedAndAToolRowWithoutAToolIs() {
        let text = markdown([
            user("   \n"), assistant(""),
            ChatMessage(id: "t", role: .tool, content: "", timestamp: ""),
        ])
        XCTAssertEqual(text, "# Lisbon trip\n\nExported 2026-10-28 14:05\n")
    }

    // MARK: Message text is data

    func testMessageTextIsKeptAsItIs() {
        let body = "Use **bold** and [a link](https://example.test/x).\n\n```swift\nlet a = 1\n```\n\n> quoted"
        XCTAssertTrue(markdown([assistant(body)]).contains("\n\n\(body)\n"))
    }

    func testControlCharactersAreDropped() {
        let text = markdown([assistant("a\u{1B}[31mred\u{0}\u{7}b\ttab")])
        XCTAssertTrue(text.contains("a[31mredb\ttab"), text)
    }

    func testAnImageWithDataIsNotEmbedded() {
        let blob = String(repeating: "QUJD", count: 50)
        let text = markdown([assistant("Look: ![a cat](data:image/png;base64,\(blob)) and ![](data:image/gif;base64,\(blob)) end")])
        XCTAssertFalse(text.contains("base64"), text)
        XCTAssertFalse(text.contains(blob))
        XCTAssertTrue(text.contains("Look: a cat and  end"), text)
        XCTAssertTrue(markdown([assistant("![x](https://example.test/x.png)")]).contains("![x](https://example.test/x.png)"),
                      "a link to a picture stays a link")
    }

    func testDataImagesGoInAnyCaseAndFormAndOtherImagesStay() {
        XCTAssertEqual(MacChatExport.strippingDataImages("a ![x](DATA:image/png;base64,AAAA) b"), "a x b")
        XCTAssertEqual(MacChatExport.strippingDataImages("![a](  <data:image/png;base64,xx>)"), "a")
        XCTAssertEqual(MacChatExport.strippingDataImages("p <IMG alt='y' SRC = 'data:image/png;base64,AAAA'> q"), "p  q")
        XCTAssertEqual(MacChatExport.strippingDataImages("<img src=\"https://example.test/a.png\"> data: ![x](https://example.test/b.png)"),
                       "<img src=\"https://example.test/a.png\"> data: ![x](https://example.test/b.png)")
        XCTAssertEqual(MacChatExport.strippingDataImages("no image here, only the word data: in text"), "no image here, only the word data: in text")
        XCTAssertEqual(MacChatExport.strippingDataImages("![a](data:x) and ![b](data:y)"), "a and b")
    }

    func testHostileImageSyntaxCostsLinearTime() {
        let started = Date()
        for hostile in [String(repeating: "![](data:", count: 100_000), String(repeating: "<img data: ", count: 100_000),
                        String(repeating: "![", count: 100_000) + "data:", String(repeating: "![a](data:x", count: 50_000)] {
            _ = MacChatExport.cleaned(hostile)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a text of open images must not stall the export")
    }

    func testAnOpenCodeFenceIsClosedSoLaterHeadingsStayHeadings() {
        let text = markdown([assistant("Before\n```python\nprint(1)"), assistant("After", at: "2026-10-28T14:04:00Z")])
        XCTAssertTrue(text.contains("print(1)\n```\n\n## Hermes (2026-10-28 14:04)"), text)
        let tilde = markdown([assistant("~~~~\ncode")])
        XCTAssertTrue(tilde.contains("code\n~~~~\n"), tilde)
    }

    func testAClosedFenceIsLeftAlone() {
        let body = "```\na\n```\ntext\n````\nb\n```\nnot closing\n````"
        XCTAssertTrue(markdown([assistant(body)]).hasSuffix("\n\n\(body)\n"))
    }

    func testTheCodeFieldIsFencedLongerThanItsOwnBackticks() {
        let text = markdown([assistant("Here", code: "a ``` b\n`````` c")])
        XCTAssertTrue(text.contains("Here\n\n```````\na ``` b\n`````` c\n```````\n"), text)
    }

    func testTheCodeFieldOfAUserRowIsLeftOutAsInFind() {
        let message = ChatMessage(id: "u", role: .user, content: "hi", timestamp: "", code: "PRIVATE-CODE")
        XCTAssertFalse(markdown([message]).contains("PRIVATE-CODE"))
    }

    func testAReplyEnvelopeBecomesABlockquoteAndTheUsersWords() {
        let sent = ReplyQuoteEnvelope.outboundText(quoting: "First line\nSecond line", message: "My answer")
        let text = markdown([user(sent)])
        XCTAssertTrue(text.contains("## You (2026-10-28 14:00)\n\n> First line\n> Second line\n\nMy answer\n"), text)
        XCTAssertFalse(text.contains("[Replying to your earlier message]"))
    }

    // MARK: Lines made from names

    func testATitleIsOneEscapedLine() {
        let text = markdown([], title: "Plan\n## injected *x* [y] #")
        XCTAssertTrue(text.hasPrefix("# Plan \\#\\# injected \\*x\\* \\[y\\] \\#\n"), text)
    }

    func testABlankTitleReadsAsTheFallback() {
        XCTAssertTrue(markdown([], title: nil).hasPrefix("# Conversation\n"))
        XCTAssertTrue(markdown([], title: " \n\t ").hasPrefix("# Conversation\n"))
    }

    func testALongTitleIsCut() {
        let first = markdown([], title: String(repeating: "word ", count: 200)).components(separatedBy: "\n")[0]
        XCTAssertLessThanOrEqual(first.count, MacChatExport.maxTitleGraphemes + 4)
    }

    func testABotNameCannotBreakItsHeading() {
        let text = markdown([assistant("Hi")], agent: "Evil\n# Fake `x`")
        XCTAssertTrue(text.contains("## Evil \\# Fake \\`x\\` (2026-10-28 14:01)\n"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }.count, 1, "only the title is a level-1 heading")
    }

    func testAToolNameIsACodeSpanThatItsBackticksCannotEnd() {
        let text = markdown([tool("a`b``c", .complete), tool("`edge`", .running), tool("line\nbreak", .complete)])
        XCTAssertTrue(text.contains("Tool: ```a`b``c``` (complete)\\\n"), text)
        XCTAssertTrue(text.contains("Tool: `` `edge` `` (running)\\\n"), text)
        XCTAssertTrue(text.contains("Tool: `line break` (complete)\n"), text)
    }

    func testAnAttachmentIsOneLineWithItsFileNameAndNoImageData() {
        let image = Attachment(id: "i", name: "cat `1`.png", uri: "data:image/png;base64,QUJDREVGRw==", mimeType: "image/png", kind: .image)
        let clip = Attachment(id: "v", name: "a\nb.mov", uri: "file:///a.mov", mimeType: nil, kind: .video)
        let text = markdown([user("see", attachments: [image, clip])])
        XCTAssertTrue(text.contains("Attachment: ``cat `1`.png``\\\nAttachment: `a b.mov`\n"), text)
        XCTAssertFalse(text.contains("base64"))
        XCTAssertFalse(text.contains("QUJD"))
    }

    func testAnAttachmentOnlyRowStillShows() {
        let file = Attachment(id: "f", name: "notes.txt", uri: "", mimeType: nil, kind: .document)
        XCTAssertTrue(markdown([user("", attachments: [file])]).contains("## You (2026-10-28 14:00)\n\nAttachment: `notes.txt`\n"))
    }

    // MARK: Document value

    func testTheDocumentCarriesWhatThePrintUses() {
        let document = MacChatExport.document(
            MacChatExportInput(title: "T", agentName: "Hermes", messages: [user("hi"), tool("grep", .running)], olderMessagesOmitted: true),
            exportedAt: now, strings: Self.english, timeZone: utc)
        XCTAssertEqual(document.title, "T")
        XCTAssertEqual(document.exported, "2026-10-28 14:05")
        XCTAssertTrue(document.olderOmitted)
        XCTAssertEqual(document.items, [
            .message(MacChatExportDocument.Message(role: .user, speaker: "You", time: "2026-10-28 14:00", text: "hi", attachments: [])),
            .tool(MacChatExportDocument.ToolStep(name: "grep", running: true)),
        ])
    }
}

// MARK: - File name

final class MacChatExportFileNameTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let day = Date(timeIntervalSince1970: 1_793_196_300) // 2026-10-28 14:05 UTC

    private func make(_ title: String?, date: Date? = nil, zone: TimeZone? = nil) -> String {
        MacChatExportFileName.make(title: title, date: date ?? day, fallback: "Conversation", timeZone: zone ?? utc)
    }

    func testATitleAndTheDateMakeTheName() {
        XCTAssertEqual(make("Weekend trip"), "Weekend trip 2026-10-28.md")
    }

    func testABlankTitleUsesTheFallback() {
        for blank in [nil, "", "   ", "\n\t", "///", "...", "\u{0}\u{1}"] {
            XCTAssertEqual(make(blank), "Conversation 2026-10-28.md", "\(String(describing: blank))")
        }
    }

    func testNoSeparatorSurvives() {
        for hostile in ["a/b", "a:b", "a\\b", "../../etc/passwd", "/etc/passwd", "~/x", "a\u{2215}b", "C:\\Windows\\x"] {
            let name = make(hostile)
            XCTAssertFalse(name.contains("/"), name)
            XCTAssertFalse(name.contains(":"), name)
            XCTAssertFalse(name.contains("\\"), name)
            XCTAssertFalse(name.hasPrefix("."), name)
            XCTAssertTrue(name.hasSuffix(" 2026-10-28.md"), name)
            XCTAssertEqual(URL(fileURLWithPath: "/tmp/out").appendingPathComponent(name).deletingLastPathComponent().path, "/tmp/out", name)
        }
    }

    func testTheNameIsNeverAHiddenFileOrADotName() {
        XCTAssertEqual(make(".bashrc"), "bashrc 2026-10-28.md")
        XCTAssertEqual(make(".."), "Conversation 2026-10-28.md")
        XCTAssertEqual(make("  .hidden  "), "hidden 2026-10-28.md")
    }

    func testControlAndBidiCharactersAreDropped() {
        let name = make("evil\u{202E}dm.txt\u{0}\n\u{7}x")
        XCTAssertFalse(name.unicodeScalars.contains { $0.value == 0x202E || $0.value < 0x20 }, name)
    }

    func testPunctuationThatFileSystemsRejectIsDroppedOrBecomesADash() {
        XCTAssertEqual(make("Q: what? why* <now> | \"x\""), "Q- what why now x 2026-10-28.md")
        XCTAssertEqual(make("a / b"), "a - b 2026-10-28.md")
    }

    func testALongTitleKeepsTheNameInsideTheFileSystemLimit() {
        for title in [String(repeating: "a", count: 400), String(repeating: "\u{4E2D}", count: 400),
                      String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 100)] {
            let name = make(title)
            XCTAssertLessThanOrEqual(name.utf8.count, 255, "\(name.utf8.count)")
            XCTAssertTrue(name.hasSuffix(" 2026-10-28.md"), name)
        }
        XCTAssertEqual(make(String(repeating: "a", count: 400)).count, MacChatExportFileName.maxTitleGraphemes + " 2026-10-28.md".count)
    }

    func testTheDateFollowsTheTimeZone() {
        let late = Date(timeIntervalSince1970: 1_793_226_000) // 2026-10-28 22:20 UTC
        XCTAssertEqual(make("x", date: late), "x 2026-10-28.md")
        XCTAssertEqual(make("x", date: late, zone: TimeZone(identifier: "Pacific/Kiritimati")!), "x 2026-10-29.md")
    }

    func testTheExtensionIsMarkdownWhateverTheTitleEndsIn() {
        XCTAssertEqual(make("notes.txt"), "notes.txt 2026-10-28.md")
        XCTAssertEqual(make("a.md"), "a.md 2026-10-28.md")
    }

    func testThePrintJobTitleHasNoExtension() {
        XCTAssertEqual(MacChatExportFileName.baseName(title: "Weekend trip", date: day, fallback: "Conversation", timeZone: utc),
                       "Weekend trip 2026-10-28")
    }
}

// MARK: - Availability

@MainActor
final class MacChatExportAvailabilityTests: XCTestCase {
    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var windows: [NSWindow] = []
    private var controllers: [MacSessionWindowController] = []

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatExportAvailabilityTests.\(UUID().uuidString)", isDirectory: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.stop() }
        controllers = []
        windows.forEach { $0.close() }
        windows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func window(_ identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        if let identifier { w.identifier = NSUserInterfaceItemIdentifier(identifier) }
        windows.append(w)
        return w
    }

    private func primary() -> NSWindow { window("conduit-primary-AppWindow-1") }
    private func sessionWindow() -> NSWindow { window("conduit-session-AppWindow-1") }

    private func controller(messages: [String]) -> MacSessionWindowController {
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "row-1")
        let controller = MacSessionWindowController(
            token: token, environment: MacSessionWindowEnvironment(), hub: MacStreamEventHub(), settleDelay: .seconds(60))
        for (index, text) in messages.enumerated() {
            controller.handle(.messageComplete(sessionId: "row-1", messageId: "m\(index)", content: text, reasoning: nil))
        }
        controllers.append(controller)
        return controller
    }

    private func say(_ text: String) -> [ChatMessage] {
        [ChatMessage(id: "m1", role: .assistant, content: text, timestamp: "")]
    }

    // MARK: The rule

    func testTheRuleForEverySurface() {
        let rule = MacChatExportAvailability.isAvailable
        XCTAssertTrue(rule(.main, true, false, true), "the main window shows a chat with messages")
        XCTAssertFalse(rule(.main, false, false, true), "Bots, Cron, Kanban, Home and Artifacts keep the chat hidden")
        XCTAssertFalse(rule(.main, true, true, true), "a group room is not a chat of this kind")
        XCTAssertFalse(rule(.main, true, false, false), "an empty chat has nothing to export")
        XCTAssertTrue(rule(.session, false, false, true), "a session window ignores the main window's tab")
        XCTAssertTrue(rule(.session, false, true, true), "and the main window's room")
        XCTAssertFalse(rule(.session, true, false, false))
        XCTAssertFalse(rule(nil, true, false, true), "no window, a sheet, a panel: nothing")
    }

    // MARK: The key window

    func testTheSurfaceOfEachWindow() {
        XCTAssertEqual(MacChatExportAvailability.surface(of: primary()), .main)
        XCTAssertEqual(MacChatExportAvailability.surface(of: sessionWindow()), .session)
        XCTAssertNil(MacChatExportAvailability.surface(of: window("com_apple_SwiftUI_Settings_window")))
        XCTAssertNil(MacChatExportAvailability.surface(of: window(nil)))
        XCTAssertNil(MacChatExportAvailability.surface(of: nil))
    }

    func testASheetAndTheWindowUnderItAreRefused() {
        for identifier in ["conduit-primary-AppWindow-1", "conduit-session-AppWindow-1"] {
            let parent = window(identifier)
            let sheet = window(nil)
            parent.orderFront(nil)
            XCTAssertNotNil(MacChatExportAvailability.surface(of: parent), identifier)
            parent.beginSheet(sheet)
            XCTAssertTrue(HostedTestSupport.waitUntil { parent.attachedSheet != nil })
            XCTAssertNil(MacChatExportAvailability.surface(of: parent), "\(identifier) under a sheet")
            XCTAssertNil(MacChatExportAvailability.surface(of: sheet), "the sheet itself")
            parent.endSheet(sheet)
        }
    }

    func testAFloatingPanelLikeQuickAskIsRefused() {
        let panel = MacFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("conduit-primary-quickask")
        XCTAssertNil(MacChatExportAvailability.surface(of: panel))
    }

    // MARK: The target

    func testTheMainWindowIsATargetOnlyOnTheChatTabWithMessages() {
        let main = primary()
        XCTAssertFalse(MacChatExportActions.isAvailable(window: main, appState: appState, tabRaw: "Sessions"), "no messages")
        appState.messages = say("hello")
        XCTAssertTrue(MacChatExportActions.isAvailable(window: main, appState: appState, tabRaw: "Sessions"))
        XCTAssertTrue(MacChatExportActions.isAvailable(window: main, appState: appState, tabRaw: nil), "no saved tab is the chat tab")
        for tab in ["Bots", "Cron", "Kanban", "Home", "Artifacts"] {
            XCTAssertFalse(MacChatExportActions.isAvailable(window: main, appState: appState, tabRaw: tab), tab)
        }
        XCTAssertFalse(MacChatExportActions.isAvailable(window: nil, appState: appState, tabRaw: "Sessions"))
        XCTAssertFalse(MacChatExportActions.isAvailable(window: window(nil), appState: appState, tabRaw: "Sessions"))
    }

    func testTheMainWindowUnderASheetIsNoTarget() {
        let main = primary()
        appState.messages = say("hello")
        let sheet = window(nil)
        main.orderFront(nil)
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertTrue(HostedTestSupport.waitUntil { main.attachedSheet != nil })
        XCTAssertNil(MacChatExportActions.target(window: main, appState: appState, tabRaw: "Sessions"))
    }

    func testASessionWindowIsATargetThroughItsController() {
        let registry = MacChatExportSessions()
        let side = sessionWindow()
        appState.messages = []
        XCTAssertNil(MacChatExportActions.target(window: side, appState: appState, tabRaw: "Kanban", sessions: registry),
                     "not registered yet")
        let chat = controller(messages: ["one"])
        registry.sync(window: side, controller: chat)
        guard case .session(let found)? = MacChatExportActions.target(
            window: side, appState: appState, tabRaw: "Kanban", sessions: registry) else {
            return XCTFail("a session window with a transcript is a target, on any main-window tab")
        }
        XCTAssertTrue(found === chat)
        registry.sync(window: side, controller: controller(messages: []))
        XCTAssertNil(MacChatExportActions.target(window: side, appState: appState, tabRaw: "Sessions", sessions: registry),
                     "an empty transcript")
        registry.sync(window: side, controller: nil)
        XCTAssertNil(registry.controller(for: side))
    }

    func testTheRegistryKeepsOneEntryPerWindowAndDropsGoneOnes() {
        let registry = MacChatExportSessions()
        let a = sessionWindow(), b = sessionWindow()
        let first = controller(messages: ["a"]), second = controller(messages: ["b"])
        registry.sync(window: a, controller: first)
        registry.sync(window: b, controller: second)
        XCTAssertTrue(registry.controller(for: a) === first)
        XCTAssertTrue(registry.controller(for: b) === second)
        registry.sync(window: a, controller: second)
        XCTAssertTrue(registry.controller(for: a) === second, "a window has one controller")
        XCTAssertNil(registry.controller(for: nil))
    }

    func testTheInputOfTheMainWindowIsItsLoadedMessages() throws {
        appState.messages = say("hello")
        let input = MacChatExportActions.input(for: .main, appState: appState)
        XCTAssertEqual(input.messages.map(\.content), ["hello"])
        XCTAssertFalse(input.olderMessagesOmitted, "no older page is waiting")
        XCTAssertFalse(input.agentName.isEmpty)
    }

    func testTheInputOfASessionWindowIsItsTranscriptAndItsProfileName() {
        let chat = controller(messages: ["one", "two"])
        let input = MacChatExportActions.input(for: .session(chat), appState: appState)
        XCTAssertEqual(input.messages.map(\.content), ["one", "two"])
        XCTAssertEqual(input.agentName, appState.profileDisplayName("default"))
        XCTAssertFalse(input.olderMessagesOmitted)
    }

    // MARK: The menu state

    func testTheMenuStatePublishesOnAKeyWindowOrSheetChange() {
        let center = NotificationCenter()
        let state = MacChatExportMenuState(center: center)
        XCTAssertEqual(state.revision, 0)
        for (index, name) in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                              NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification].enumerated() {
            center.post(name: name, object: nil)
            XCTAssertTrue(HostedTestSupport.waitUntil { state.revision == index + 1 }, "\(name.rawValue)")
        }
    }
}

// MARK: - Actions

@MainActor
final class MacChatExportActionTests: XCTestCase {
    private final class Presenter: MacChatExportPresenting {
        var destination: URL?
        private(set) var suggested: [String] = []
        private(set) var windows: [NSWindow?] = []
        private(set) var failures: [Error] = []
        func chooseDestination(suggestedName: String, window: NSWindow?) async -> URL? {
            suggested.append(suggestedName)
            windows.append(window)
            return destination
        }
        func showFailure(_ error: Error, window: NSWindow?) { failures.append(error) }
    }

    private final class Runner: MacChatPrintRunning {
        private(set) var jobs: [MacChatPrintJob] = []
        private(set) var windows: [NSWindow?] = []
        func run(_ job: MacChatPrintJob, window: NSWindow?) {
            jobs.append(job)
            windows.append(window)
        }
    }

    private var suite: (defaults: UserDefaults, name: String)!
    private var scratch: URL!
    private var appState: AppState!
    private var windows: [NSWindow] = []
    private var controllers: [MacSessionWindowController] = []
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_793_196_300) // 2026-10-28 14:05 UTC
    private let english = MacChatExportBuilderTests.english

    override func setUp() async throws {
        suite = HostedTestSupport.makeSuite()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatExportActionTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        appState = ArtifactsTestSupport.isolatedAppState(defaults: suite.defaults, scratch: scratch)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.stop() }
        controllers = []
        windows.forEach { $0.close() }
        windows = []
        appState = nil
        HostedTestSupport.dropSuite(suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func window(_ identifier: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                         styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier(identifier)
        windows.append(w)
        return w
    }

    private func primary() -> NSWindow { window("conduit-primary-AppWindow-1") }

    private func chat(_ messages: [ChatMessage]) { appState.messages = messages }

    /// The main window's title and the name made from it: the app's own "New conversation", in whatever language
    /// the test machine runs.
    private func titleLine(_ title: String) -> String {
        "# " + MacChatExportMarkdown.escaped(MacChatExport.oneLine(title, max: MacChatExport.maxTitleGraphemes))
    }

    private func fileName(_ title: String) -> String {
        MacChatExportFileName.make(title: title, date: now, fallback: "Conversation", timeZone: utc)
    }

    private func exampleChat() -> [ChatMessage] {
        [
            ChatMessage(id: "u1", role: .user, content: "Zo\u{EB} asks: \u{65E5}\u{672C}\u{8A9E}?", timestamp: "2026-10-28T14:00:00Z"),
            ChatMessage(id: "a1", role: .assistant, content: "Here you go.", timestamp: "2026-10-28T14:01:00Z",
                        reasoning: "SECRET-THINKING"),
        ]
    }

    private func export(
        window: NSWindow?, tab: String = "Sessions", presenter: Presenter, sessions: MacChatExportSessions? = nil,
        write: ((String, URL) throws -> Void)? = nil
    ) async -> MacChatExportActions.Outcome {
        await MacChatExportActions.export(
            window: window, appState: appState, tabRaw: tab, now: now, sessions: sessions, presenter: presenter,
            strings: english, timeZone: utc, write: write)
    }

    // MARK: Export

    func testExportWritesUTF8MarkdownToTheChosenFile() async throws {
        chat(exampleChat())
        let presenter = Presenter()
        let target = scratch.appendingPathComponent("chosen.md")
        presenter.destination = target
        let main = primary()
        let outcome = await export(window: main, presenter: presenter)
        XCTAssertEqual(outcome, .written(target))
        let data = try Data(contentsOf: target)
        XCTAssertNotEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "no byte order mark")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(titleLine(appState.activeSessionTitle)
            + "\n\nExported 2026-10-28 14:05\n\n## You (2026-10-28 14:00)\n\nZo\u{EB} asks: \u{65E5}\u{672C}\u{8A9E}?\n"), text)
        XCTAssertTrue(text.contains("## \(appState.conversationAgentIdentity.name) (2026-10-28 14:01)\n\nHere you go.\n"), text)
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(presenter.windows.first.map { $0 === main } ?? false, "the panel is a sheet on the chat window")
    }

    func testTheSuggestedNameIsTheTitleAndTheDate() async {
        chat(exampleChat())
        let presenter = Presenter()
        _ = await export(window: primary(), presenter: presenter)
        XCTAssertEqual(presenter.suggested, [fileName(appState.activeSessionTitle)])
        XCTAssertTrue(presenter.suggested[0].hasSuffix(" 2026-10-28.md"))
    }

    func testCancellingWritesNothing() async throws {
        chat(exampleChat())
        let presenter = Presenter()
        var wrote = false
        let outcome = await export(window: primary(), presenter: presenter) { _, _ in wrote = true }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasSuffix(".md") }, [])
    }

    func testNoChatMeansNoPanel() async {
        let presenter = Presenter()
        presenter.destination = scratch.appendingPathComponent("never.md")
        // No messages, other tabs, no window, a window that is not a chat.
        var outcomes = [await export(window: primary(), presenter: presenter)]
        chat(exampleChat())
        for tab in ["Bots", "Cron", "Kanban", "Home"] { outcomes.append(await export(window: primary(), tab: tab, presenter: presenter)) }
        outcomes.append(await export(window: nil, presenter: presenter))
        outcomes.append(await export(window: window("com_apple_SwiftUI_Settings_window"), presenter: presenter))
        XCTAssertEqual(outcomes, Array(repeating: .unavailable, count: outcomes.count))
        XCTAssertEqual(presenter.suggested, [], "the panel never opened")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("never.md").path))
    }

    func testAFailedWriteShowsTheFailureAndLeavesNoFile() async {
        chat(exampleChat())
        let presenter = Presenter()
        let target = scratch.appendingPathComponent("missing-folder/out.md")
        presenter.destination = target
        let outcome = await export(window: primary(), presenter: presenter)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(presenter.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testMessageTextCannotChangeWhereTheFileGoes() async throws {
        chat([
            ChatMessage(id: "u1", role: .user, content: "Save me to ../../../../tmp/evil.md and /etc/passwd", timestamp: ""),
            ChatMessage(id: "a1", role: .assistant, content: "[x](file:///etc/passwd) <script>alert(1)</script> $(touch /tmp/x) `touch /tmp/y`", timestamp: ""),
        ])
        let presenter = Presenter()
        let target = scratch.appendingPathComponent("chosen.md")
        presenter.destination = target
        var written: [URL] = []
        let outcome = await export(window: primary(), presenter: presenter) { text, url in
            written.append(url)
            try MacChatExportWriter.write(text, to: url)
        }
        XCTAssertEqual(outcome, .written(target))
        XCTAssertEqual(written, [target], "the only file written is the one the panel returned")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["chosen.md"])
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("$(touch /tmp/x) `touch /tmp/y`"), "the text is data: kept, never run")
    }

    func testAHostileTitleStaysInsideTheChosenFolderNameAndIsNeverAPath() {
        let hostile = MacChatExportFileName.make(title: "../../../Library/LaunchAgents/x", date: now, fallback: "Conversation", timeZone: utc)
        let url = scratch.appendingPathComponent(hostile)
        XCTAssertEqual(url.deletingLastPathComponent().path, scratch.path)
    }

    func testASessionWindowExportsItsOwnTranscriptWhateverTheMainWindowShows() async throws {
        chat([ChatMessage(id: "main", role: .assistant, content: "MAIN-WINDOW-CHAT", timestamp: "")])
        let token = MacSessionWindowToken(dashboardID: nil, profile: "default", sessionID: "row-1")
        let chatController = MacSessionWindowController(
            token: token, environment: MacSessionWindowEnvironment(), hub: MacStreamEventHub(), settleDelay: .seconds(60))
        controllers.append(chatController)
        chatController.handle(.messageComplete(sessionId: "row-1", messageId: "m1", content: "SESSION-WINDOW-CHAT", reasoning: nil))
        let side = window("conduit-session-AppWindow-1")
        let registry = MacChatExportSessions()
        registry.sync(window: side, controller: chatController)
        let presenter = Presenter()
        let target = scratch.appendingPathComponent("session.md")
        presenter.destination = target
        let outcome = await export(window: side, tab: "Kanban", presenter: presenter, sessions: registry)
        XCTAssertEqual(outcome, .written(target))
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("SESSION-WINDOW-CHAT"))
        XCTAssertFalse(text.contains("MAIN-WINDOW-CHAT"))
        XCTAssertTrue(text.hasPrefix(titleLine(chatController.title) + "\n"), text)
        XCTAssertTrue(text.contains("## \(appState.profileDisplayName("default"))"), text)
        XCTAssertEqual(presenter.suggested, [fileName(chatController.title)])
    }

    // MARK: Print

    func testPrintHandsTheChatToThePrintRunner() throws {
        chat(exampleChat())
        let runner = Runner()
        let main = primary()
        XCTAssertTrue(MacChatExportActions.printChat(
            window: main, appState: appState, tabRaw: "Sessions", now: now, runner: runner, strings: english, timeZone: utc))
        let job = try XCTUnwrap(runner.jobs.first)
        XCTAssertEqual(job.title, String(fileName(appState.activeSessionTitle).dropLast(3)), "Save as PDF proposes this name")
        let text = job.content.string
        XCTAssertTrue(text.contains("Here you go."))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(runner.windows.first.map { $0 === main } ?? false, "the print panel is a sheet on the chat window")
    }

    func testPrintDoesNothingWithoutAChat() {
        let runner = Runner()
        XCTAssertFalse(MacChatExportActions.printChat(
            window: primary(), appState: appState, tabRaw: "Sessions", runner: runner, strings: english))
        chat(exampleChat())
        XCTAssertFalse(MacChatExportActions.printChat(
            window: primary(), appState: appState, tabRaw: "Cron", runner: runner, strings: english))
        XCTAssertFalse(MacChatExportActions.printChat(
            window: nil, appState: appState, tabRaw: "Sessions", runner: runner, strings: english))
        XCTAssertEqual(runner.jobs.count, 0)
    }
}

// MARK: - Print

@MainActor
final class MacChatPrintTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_793_196_300)
    private let english = MacChatExportBuilderTests.english
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacChatPrintTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func document(_ messages: [ChatMessage], older: Bool = false) -> MacChatExportDocument {
        MacChatExport.document(
            MacChatExportInput(title: "Lisbon trip", agentName: "Hermes", messages: messages, olderMessagesOmitted: older),
            exportedAt: now, strings: english, timeZone: utc)
    }

    private func printed(_ messages: [ChatMessage], older: Bool = false) -> NSAttributedString {
        MacChatPrintContent.attributedString(document(messages, older: older), strings: english)
    }

    private var sample: [ChatMessage] {
        [
            ChatMessage(id: "u", role: .user, content: "Plan **a trip**", timestamp: "2026-10-28T14:00:00Z", attachments: [
                Attachment(id: "f", name: "map.pdf", uri: "data:application/pdf;base64,QUJD", mimeType: nil, kind: .document),
            ]),
            ChatMessage(id: "a", role: .assistant,
                        content: "# Plan\n\nSee [the docs](https://example.test/docs) and `code`.\n\n- one\n- two\n\n1. first\n\n> quoted\n\n```swift\nlet a = 1\n```\n\n| h1 | h2 |\n| --- | --- |\n| c1 | c2 |",
                        timestamp: "2026-10-28T14:01:00Z", reasoning: "SECRET-THINKING"),
            ChatMessage(id: "t", role: .tool, content: "", timestamp: "",
                        tool: ToolActivity(id: nil, name: "web_search", input: nil, output: nil, status: .complete)),
        ]
    }

    func testTheTextHasTheHeadingsTheMessagesTheToolLineAndTheAttachment() {
        let text = printed(sample, older: true).string
        for expected in ["Lisbon trip", "Exported 2026-10-28 14:05", "Older messages are not included in this export.",
                         "You  (2026-10-28 14:00)", "Plan a trip", "Attachment: map.pdf", "Hermes  (2026-10-28 14:01)",
                         "See the docs (https://example.test/docs) and code.", "\u{2022} one", "\u{2022} two", "1. first",
                         "quoted", "let a = 1", "h1 | h2", "c1 | c2", "Tool: web_search (complete)"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)")
        }
        for left in ["SECRET", "base64", "**", "```"] { XCTAssertFalse(text.contains(left), left) }
    }

    func testEveryRunPrintsBlackAndNoRunIsALinkOrDarkFilled() throws {
        let content = printed(sample)
        var runs = 0
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, _, _ in
            runs += 1
            XCTAssertNil(attributes[.link], "paper has no click, and a link color is not black")
            guard let color = attributes[.foregroundColor] as? NSColor else { return XCTFail("a run has no fixed color") }
            let dark = NSAppearance(named: .darkAqua)!
            var rgb: [CGFloat] = []
            dark.performAsCurrentDrawingAppearance {
                if let resolved = color.usingColorSpace(.sRGB) { rgb = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent] }
            }
            XCTAssertEqual(rgb, [0, 0, 0], "text is black even when the app is in dark mode")
            if let fill = attributes[.backgroundColor] as? NSColor {
                XCTAssertGreaterThan(fill.usingColorSpace(.sRGB)?.brightnessComponent ?? 0, 0.85, "only a light fill sits behind code")
            }
        }
        XCTAssertGreaterThan(runs, 5)
    }

    func testBoldAndCodeKeepTheirFonts() throws {
        let content = printed(sample)
        let manager = NSFontManager.shared
        let boldRange = (content.string as NSString).range(of: "a trip")
        let boldFont = try XCTUnwrap(content.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(manager.traits(of: boldFont).contains(.boldFontMask))
        let codeRange = (content.string as NSString).range(of: "let a = 1")
        let codeFont = try XCTUnwrap(content.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch, "code prints in a fixed-pitch font")
    }

    func testTheViewIsWhiteLightTextKit1AtThePrintableWidth() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.leftMargin = MacChatPrintView.margin
        info.rightMargin = MacChatPrintView.margin
        let view = MacChatPrintView.view(for: printed(sample), printInfo: info)
        XCTAssertEqual(view.frame.width, 612 - 2 * MacChatPrintView.margin)
        XCTAssertGreaterThan(view.frame.height, 0)
        XCTAssertEqual(view.backgroundColor, NSColor.white)
        XCTAssertTrue(view.drawsBackground)
        XCTAssertEqual(view.appearance?.name, .aqua)
        XCTAssertNil(view.textLayoutManager, "TextKit 1 (D13), whose page breaks keep a line whole")
        XCTAssertFalse(view.isEditable)
    }

    func testTheOperationHasTheJobTitleAndFitsTheWidth() {
        let operation = MacChatPrintView.operation(for: MacChatPrintJob(title: "Lisbon trip 2026-10-28", content: printed(sample)))
        XCTAssertEqual(operation.jobTitle, "Lisbon trip 2026-10-28")
        XCTAssertEqual(operation.printInfo.horizontalPagination, .fit)
        XCTAssertEqual(operation.printInfo.verticalPagination, .automatic)
        XCTAssertTrue(operation.showsPrintPanel, "the system print panel is how a person picks the printer or Save as PDF")
    }

    /// The real operation, with its panel off and the pages sent to a PDF file: a long chat takes several
    /// pages, and the pages are dark text on white while the app is in dark mode.
    func testALongChatPrintsOnSeveralWhitePagesInDarkMode() throws {
        let long = (1...120).map { index in
            ChatMessage(id: "m\(index)", role: index % 2 == 0 ? .assistant : .user,
                        content: "Paragraph \(index). " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 12),
                        timestamp: "2026-10-28T14:00:00Z")
        }
        let url = scratch.appendingPathComponent("chat.pdf")
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let job = MacChatPrintJob(title: "Long chat", content: printed(long))
        let operation = MacChatPrintView.operation(for: job, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previous }
        XCTAssertTrue(operation.run())

        let pdf = try XCTUnwrap(PDFDocument(url: url), "the print operation wrote no PDF")
        XCTAssertGreaterThan(pdf.pageCount, 1, "a long chat paginates")
        XCTAssertTrue(pdf.string?.contains("Lisbon trip") ?? false)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 306, height: 396), for: .mediaBox)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var dark = 0, total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                total += 1
                if (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.4 { dark += 1 }
            }
        }
        let corner = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.95, "the paper is white")
        XCTAssertGreaterThan(dark, 0, "there is dark text")
        XCTAssertLessThan(Double(dark) / Double(total), 0.25, "and the page is not a dark fill")
    }
}

// MARK: - Menu, source and catalog pins

@MainActor
final class MacChatExportWiringTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(file), encoding: .utf8)
    }

    private func entries(_ menu: NSMenu, path: String = "") -> [(path: String, item: NSMenuItem)] {
        menu.items.flatMap { item -> [(path: String, item: NSMenuItem)] in
            let here = path + "/" + item.title
            return [(here, item)] + (item.submenu.map { entries($0, path: here) } ?? [])
        }
    }

    func testTheFileMenuHasBothItemsOnTheirKeysAndNoOtherPrintItem() throws {
        let all = entries(try XCTUnwrap(NSApp.mainMenu, "SwiftUI has not built the main menu"))
        let paths = all.map(\.path)
        let export = try XCTUnwrap(all.first { $0.path == "/File/Export Chat\u{2026}" }, "\(paths)")
        XCTAssertEqual(export.item.keyEquivalent, "e")
        XCTAssertEqual(export.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.shift, .command])
        let print = try XCTUnwrap(all.first { $0.path == "/File/Print Chat\u{2026}" }, "\(paths)")
        XCTAssertEqual(print.item.keyEquivalent, "p")
        XCTAssertEqual(print.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), .command)
        let cmdP = all.filter { $0.item.keyEquivalent == "p"
            && $0.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command }.map(\.path)
        XCTAssertEqual(cmdP, ["/File/Print Chat\u{2026}"], "the system Print item is replaced, so Cmd-P has one owner")
        XCTAssertEqual(all.filter { $0.path.hasPrefix("/File/Print") }.map(\.path), ["/File/Print Chat\u{2026}"])
    }

    func testTheCommandsFileDisablesBothItemsFromTheSameRule() throws {
        let commands = try source("ConduitMac/App/ConduitCommands.swift")
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .printItem)"))
        XCTAssertTrue(commands.contains("Button(\"Export Chat\\u{2026}\")"))
        XCTAssertTrue(commands.contains("Button(\"Print Chat\\u{2026}\")"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"e\", modifiers: [.shift, .command])"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"p\", modifiers: .command)"))
        let rule = ".disabled(!MacChatExportActions.isAvailable(window: NSApp.keyWindow, appState: appState, tabRaw: sidebarTab))"
        XCTAssertEqual(commands.components(separatedBy: rule).count - 1, 2)
        XCTAssertTrue(commands.contains("@ObservedObject private var chatExportMenu = MacChatExportMenuState.shared"),
                      "the menu is rebuilt when the key window or a sheet changes")
    }

    func testTheSessionWindowSceneRegistersItsControllerForTheExport() throws {
        let scene = try source("ConduitMac/Windows/MacSessionWindows.swift")
        XCTAssertTrue(scene.contains("MacChatExportSessions.shared.sync(window: window, controller: controller)"))
    }

    // MARK: Catalog

    private let languages = ["de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Conduit/Localizable.xcstrings"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func values(_ entry: [String: Any]?) throws -> [String: String] {
        let localizations = try XCTUnwrap(entry?["localizations"] as? [String: [String: Any]])
        return localizations.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    func testEveryNewKeyHasAllLanguagesAndTheEnglishOnesHaveEnglishToo() throws {
        let all = try catalog()
        let withEnglish = ["Mac.ChatExport.OlderNotIncluded", "Mac.ChatExport.ToolRunning", "Mac.ChatExport.ToolComplete",
                           "Mac.ChatExport.SaveButton", "Mac.ChatExport.WriteFailed", "Export Chat\u{2026}", "Print Chat\u{2026}"]
        let englishIsTheKey = ["Exported %@", "Tool: %@ (%@)", "Attachment: %@"]
        for key in withEnglish + englishIsTheKey {
            let found = try values(all[key])
            let wanted = Set(languages + (withEnglish.contains(key) ? ["en"] : []))
            XCTAssertEqual(Set(found.keys), wanted, key)
            for (language, value) in found { XCTAssertFalse(value.isEmpty, "\(key) [\(language)]") }
        }
        for key in englishIsTheKey {
            let placeholders = key.components(separatedBy: "%@").count - 1
            for (language, value) in try values(all[key]) {
                XCTAssertEqual(value.components(separatedBy: "@").count - 1, placeholders, "\(key) [\(language)]: placeholders")
            }
        }
    }

    func testTheLiveStringsResolveAndKeepTheirPlaceholders() {
        let live = MacChatExportStrings.live
        for text in [live.you, live.fallbackTitle, live.olderNotIncluded, live.toolRunning, live.toolComplete,
                     live.exported("DATE"), live.toolLine("NAME", "STATUS"), live.attachment("FILE")] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.hasPrefix("Mac.ChatExport."), "an unresolved key: \(text)")
            XCTAssertFalse(text.contains("%@"), text)
        }
        XCTAssertTrue(live.exported("DATE").contains("DATE"))
        XCTAssertTrue(live.toolLine("NAME", "STATUS").contains("NAME") && live.toolLine("NAME", "STATUS").contains("STATUS"))
        XCTAssertTrue(live.attachment("FILE").contains("FILE"))
    }
}
