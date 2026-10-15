import AppKit
import XCTest
@testable import ConduitMac

@MainActor
final class MacServicesProviderTests: XCTestCase {
    private var board: NSPasteboard!
    private var received: [String] = []

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("conduit.tests.\(UUID().uuidString)"))
        received = []
    }

    override func tearDown() {
        board.releaseGlobally()
        board = nil
    }

    private var noTextMessage: String { AppLocalization.string("No text selected") }

    private func call(_ provider: MacServicesProvider) -> String? {
        var message: NSString = ""
        provider.sendToHermes(board, userData: "", error: &message)
        return message.length == 0 ? nil : message as String
    }

    private func provider() -> MacServicesProvider {
        MacServicesProvider { [unowned self] in self.received.append($0) }
    }

    func testProviderDeliversPlainText() {
        board.clearContents()
        board.setString("  selected text ", forType: .string)
        XCTAssertNil(call(provider()))
        XCTAssertTrue(HostedTestSupport.waitUntil { received == ["selected text"] }, "\(received)")
    }

    func testProviderFlattensRichText() throws {
        board.clearContents()
        let rtf = try NSAttributedString(string: "bold words").data(
            from: NSRange(location: 0, length: 10),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        XCTAssertNil(call(provider()))
        XCTAssertTrue(HostedTestSupport.waitUntil { received == ["bold words"] }, "\(received)")
    }

    func testProviderRejectsEmptyAndNonStringBoards() {
        board.clearContents()
        XCTAssertEqual(call(provider()), noTextMessage)
        board.setString("   ", forType: .string)
        XCTAssertEqual(call(provider()), noTextMessage)
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertEqual(call(provider()), noTextMessage)
        XCTAssertTrue(received.isEmpty)
    }

    func testSelectorNameMatchesTheMethod() {
        XCTAssertTrue(MacServicesProvider.instancesRespond(to: Selector(("\(MacServicesProvider.selectorName):userData:error:"))))
    }
}
