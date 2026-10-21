import Contacts
@testable import ConduitMac
import XCTest

/// The Mac "Add to Contacts" action on a contact card (Ruling R23): the card becomes a vCard that Contacts opens.
final class RichContactVCardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichContactVCardTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func person(name: String = "Ada Lovelace") throws -> RichPerson {
        try XCTUnwrap(RichPerson(json: [
            "name": name,
            "detail": "Mathematician",
            "phone": "+44 20 7946 0958",
            "email": "ada@example.com",
            "url": "https://example.com/ada"
        ]))
    }

    func testVCardCarriesNamePhoneAndEmailFromTheCard() throws {
        let data = try RichContactVCard.vCardData(for: person())
        let parsed = try XCTUnwrap(CNContactVCardSerialization.contacts(with: data).first)
        XCTAssertEqual(parsed.givenName, "Ada")
        XCTAssertEqual(parsed.familyName, "Lovelace")
        XCTAssertEqual(parsed.jobTitle, "Mathematician")
        XCTAssertEqual(parsed.phoneNumbers.map { $0.value.stringValue }, ["+44 20 7946 0958"])
        XCTAssertEqual(parsed.emailAddresses.map { $0.value as String }, ["ada@example.com"])
        XCTAssertEqual(parsed.urlAddresses.map { $0.value as String }, ["https://example.com/ada"])
    }

    func testOneWordNameIsTheGivenName() throws {
        let data = try RichContactVCard.vCardData(for: person(name: "Cher"))
        let parsed = try XCTUnwrap(CNContactVCardSerialization.contacts(with: data).first)
        XCTAssertEqual(parsed.givenName, "Cher")
        XCTAssertEqual(parsed.familyName, "")
    }

    func testOpenWritesTheCardToAVCardFileAndHandsItToTheOpener() throws {
        var opened: [URL] = []
        let ok = RichContactVCard.openInContacts(try person(), directory: directory, open: { url in
            opened.append(url)
            return true
        }, reveal: { _ in })
        XCTAssertTrue(ok)
        let url = try XCTUnwrap(opened.first)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(url.pathExtension, "vcf")
        let parsed = try XCTUnwrap(CNContactVCardSerialization.contacts(with: Data(contentsOf: url)).first)
        XCTAssertEqual(parsed.givenName, "Ada")
        XCTAssertEqual(parsed.emailAddresses.map { $0.value as String }, ["ada@example.com"])
    }

    func testFileStaysInsideTheFolderWhateverTheName() throws {
        var opened: [URL] = []
        _ = RichContactVCard.openInContacts(try person(name: "../../evil/ Name"), directory: directory, open: { url in
            opened.append(url)
            return true
        }, reveal: { _ in })
        let url = try XCTUnwrap(opened.first)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOpenRevealsTheFileWhenTheOpenerRefuses() throws {
        var revealed: [URL] = []
        let ok = RichContactVCard.openInContacts(
            try person(), directory: directory, open: { _ in false }, reveal: { revealed.append($0) }
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(revealed.map(\.pathExtension), ["vcf"])
    }

    func testOpenDoesNotRevealWhenTheOpenerSucceeds() throws {
        var revealed: [URL] = []
        _ = RichContactVCard.openInContacts(
            try person(), directory: directory, open: { _ in true }, reveal: { revealed.append($0) }
        )
        XCTAssertTrue(revealed.isEmpty)
    }
}
