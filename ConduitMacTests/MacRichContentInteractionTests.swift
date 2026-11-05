import XCTest
@testable import ConduitMac

/// Right-click forms of the rich-content interactions that upstream opens only
/// with touch and hold (Task 11 of the 2026-10-21 upstream sync).
///
/// Source pins, as in `MacPaneTitleTests.testRootViewAppliesTheRemovalToTheChatStack`:
/// the composer's action button is a `Menu` with a primary action, and a
/// pull-down menu button on macOS takes a click, not a right-click. The Mac
/// region draws a `Button` with a `.contextMenu` of the same choices.
///
/// Copy Table and Select Text (#693) need no Mac form: `MarkdownTableMenu` is
/// already a `.contextMenu`, which is a right-click on macOS.
final class MacRichContentInteractionTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of `ComposerBar.composerActionButton`, split at the Mac region.
    private func composerActionButton() throws -> (mac: String, other: String) {
        let file = try source("Conduit/Views/Components/ComposerBar.swift")
        let start = try XCTUnwrap(file.range(of: "private var composerActionButton: some View {"),
                                  "ComposerBar.composerActionButton must exist")
        let end = try XCTUnwrap(file.range(of: "private func performComposerAction()", range: start.upperBound..<file.endIndex))
        let body = String(file[start.upperBound..<end.lowerBound])

        let open = try XCTUnwrap(body.range(of: "#if os(macOS) // MAC:"),
                                 "composerActionButton must hold a `#if os(macOS) // MAC:` region")
        let split = try XCTUnwrap(body.range(of: "#else // MAC:", range: open.upperBound..<body.endIndex),
                                  "the Mac region must keep upstream's Menu in its `#else // MAC:` branch")
        let close = try XCTUnwrap(body.range(of: "#endif // MAC:", range: split.upperBound..<body.endIndex),
                                  "the Mac region must close with `#endif // MAC:`")
        return (String(body[open.upperBound..<split.lowerBound]), String(body[split.upperBound..<close.lowerBound]))
    }

    /// The send options (#966, #1028) open with a right-click on Mac.
    func testComposerSendOptionsOpenWithARightClickOnMac() throws {
        let (mac, other) = try composerActionButton()

        XCTAssertTrue(mac.contains(".contextMenu {"), "the Mac send button must carry a .contextMenu")
        XCTAssertTrue(mac.contains("ForEach(choices)"), "the context menu must list the same `choices` as upstream's Menu")
        XCTAssertTrue(mac.contains("submit(choice)"), "a picked choice must send the way upstream's Menu sends it")
        XCTAssertTrue(mac.contains("Label(choice.title, systemImage: choice.symbol)"),
                      "each item must show the choice's title and symbol, like upstream's Menu")
        XCTAssertTrue(mac.contains("Button(action: performComposerAction)"), "a left click must still run the primary action")
        XCTAssertFalse(mac.replacingOccurrences(of: ".contextMenu", with: "").contains("Menu {"),
                       "a Menu takes a click, not a right-click, on macOS")
        // The hint names the gesture the Mac uses; "Touch and hold" is the iOS hint in the `#else` branch.
        XCTAssertTrue(mac.contains(#".accessibilityHint(AppLocalization.string("Right-click for other ways to send"))"#),
                      "the Mac hint must say right-click")
        XCTAssertFalse(mac.contains("Touch and hold"), "the Mac region must not name a touch gesture")

        // Upstream's form stays in the `#else` branch, so iOS and the diff to upstream do not change.
        XCTAssertTrue(other.contains("Menu {"))
        XCTAssertTrue(other.contains("primaryAction:"))
        XCTAssertTrue(other.contains(#".accessibilityHint(AppLocalization.string("Touch and hold for other ways to send"))"#))
        XCTAssertTrue(other.contains("Label(choice.title, systemImage: choice.symbol)"))
    }

    /// The items are the ones the touch-and-hold menu offers: idle send lists the side agents; a busy
    /// turn lists the busy modes the tap does not use, then the side agents.
    func testSendChoicesAreTheTouchAndHoldItems() {
        XCTAssertEqual(ComposerSendChoice.choices(for: .send, hasAttachments: false, isSlashCommand: false).map(\.rawValue),
                       ["background", "btw"])
        XCTAssertEqual(ComposerSendChoice.choices(for: .steer, hasAttachments: false, isSlashCommand: false).map(\.rawValue),
                       ["queue", "interrupt", "background", "btw"])
        XCTAssertEqual(ComposerSendChoice.choices(for: .send, hasAttachments: true, isSlashCommand: false), [],
                       "no menu for attachments, so no right-click menu either")
        // The five titles the touch-and-hold menu shows, which the right-click menu shows too.
        XCTAssertEqual(ComposerSendChoice.allCases.map(\.title),
                       ["Steer", "Interrupt", "Queue", "Background", "Side question"])
        for choice in ComposerSendChoice.allCases {
            XCTAssertFalse(choice.symbol.isEmpty, "\(choice): an item needs a symbol")
        }
    }
}
