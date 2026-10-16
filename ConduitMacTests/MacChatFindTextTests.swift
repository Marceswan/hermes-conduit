import XCTest
@testable import ConduitMac

@MainActor
final class MacChatFindTextTests: XCTestCase {
    private func message(_ id: String, _ role: MessageRole, _ content: String, code: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content, timestamp: "", code: code)
    }

    func testLinkDestinationIsNotSearchable() {
        let text = MacChatFindText.plain(fromMarkdown: "See [the docs](https://example.com/guide) now")
        XCTAssertTrue(text.contains("the docs"))
        XCTAssertFalse(text.contains("example"))
        XCTAssertFalse(text.contains("]("))
    }

    func testEmphasisAndCodeSpansAreStripped() {
        let text = MacChatFindText.plain(fromMarkdown: "**bold** and `code` and *it*")
        XCTAssertTrue(text.contains("bold and code and it"))
        XCTAssertFalse(text.contains("*"))
        XCTAssertFalse(text.contains("`"))
    }

    func testFenceMarkersAreAbsentButCodeIsKept() {
        let text = MacChatFindText.plain(fromMarkdown: "Run:\n\n```swift\nlet x = 1\n```\n")
        XCTAssertTrue(text.contains("let x = 1"))
        XCTAssertFalse(text.contains("```"))
    }

    func testTableSeparatorsAreAbsentButCellsAreKept() {
        let text = MacChatFindText.plain(fromMarkdown: "| h1 | h2 |\n|---|---|\n| c1 | c2 |\n")
        for cell in ["h1", "h2", "c1", "c2"] { XCTAssertTrue(text.contains(cell), cell) }
        XCTAssertFalse(text.contains("---"))
        XCTAssertFalse(text.contains("|"))
    }

    func testListMarkersAndHeadingHashesAreAbsent() {
        let text = MacChatFindText.plain(fromMarkdown: "# Title\n\n- one\n- two\n")
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("one"))
        XCTAssertTrue(text.contains("two"))
        XCTAssertFalse(text.contains("# "))
        XCTAssertFalse(text.contains("- one"))
    }

    func testFlowListsDrawTheirMarkersInTheProjection() {
        let text = MacChatFindText.plain(fromMarkdown: "1. first\n2. second\n\n- a\n- b\n\n- [ ] todo\n- [x] done\n")
        XCTAssertEqual(text, "1. first\n2. second\n\u{2022} a\n\u{2022} b\n\u{2610} todo\n\u{2611} done")
    }

    func testFlowQuotesDrawTheirBarsInTheProjection() {
        let text = MacChatFindText.plain(fromMarkdown: "> one\n> > two\n")
        XCTAssertEqual(text, "\u{2502} one\n\u{2502} \u{2502} two")
    }

    func testRichMessagesKeepMarkersOutOfTheProjectionButStripTaskPrefixes() {
        // A table moves the message to per-block views; their markers are
        // separate Text views, not text-view characters.
        let text = MacChatFindText.plain(fromMarkdown: "- [x] done\n- plain\n\n| h1 | h2 |\n|---|---|\n| c1 | c2 |\n")
        XCTAssertTrue(text.hasPrefix("done\nplain\n"), text)
        XCTAssertFalse(text.contains("\u{2022}"))
    }

    func testOnlyUserAssistantAndPartialRowsAreSearchable() {
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("u", .user, "hi there")))
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("a", .assistant, "hello")))
        XCTAssertNotNil(MacChatFindText.searchableText(for: message("p", .partial, "partial")))
        for role in [MessageRole.system, .reasoning, .tool, .clarify, .approval, .inputPrompt] {
            XCTAssertNil(MacChatFindText.searchableText(for: message("x", role, "text")), "\(role)")
        }
    }

    func testEmptyOrBlankContentIsNotSearchable() {
        XCTAssertNil(MacChatFindText.searchableText(for: message("a", .assistant, "")))
        XCTAssertNil(MacChatFindText.searchableText(for: message("a", .assistant, " \n ")))
    }

    func testReplyQuoteEnvelopeIsRemovedFromUserRows() {
        let sent = ReplyQuoteEnvelope.outboundText(quoting: "earlier reply words", message: "my own words")
        let text = MacChatFindText.searchableText(for: message("u", .user, sent))
        XCTAssertEqual(text, "my own words")
    }

    func testAssistantCodeBlockIsAppendedAfterTheText() {
        let text = MacChatFindText.searchableText(for: message("a", .assistant, "before", code: "let needle = 1"))
        XCTAssertEqual(text, "before\nlet needle = 1")
        XCTAssertNil(
            MacChatFindText.searchableText(for: message("u", .user, "", code: "ignored")),
            "a user row draws no code block"
        )
    }

    func testCacheReturnsEntriesInOrderAndSkipsUnsearchableRows() {
        let cache = MacChatFindTextCache()
        let entries = cache.entries(for: [
            message("1", .user, "alpha"),
            message("2", .tool, "skipped"),
            message("3", .assistant, "beta"),
        ])
        XCTAssertEqual(entries.map(\.id), ["1", "3"])
        XCTAssertEqual(entries.map(\.text), ["alpha", "beta"])
    }

    func testCacheNoticesAnEditedMessage() {
        let cache = MacChatFindTextCache()
        _ = cache.entries(for: [message("1", .assistant, "old")])
        let entries = cache.entries(for: [message("1", .assistant, "new")])
        XCTAssertEqual(entries.map(\.text), ["new"])
    }

    func testPrimeFillsTheCacheWithoutChangingResults() async {
        let cache = MacChatFindTextCache()
        let messages = (0..<130).map { message("m\($0)", .assistant, "text \($0)") }
        await cache.prime(messages, chunk: 40)
        let entries = cache.entries(for: messages)
        XCTAssertEqual(entries.count, 130)
        XCTAssertEqual(entries[129].text, "text 129")
    }
}
