import Contacts
@testable import ConduitMac
import XCTest

/// The Mac "Add to Contacts" action on a contact card (Ruling R23): the card becomes a vCard that Contacts opens.
@MainActor
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

    // MARK: Opening

    /// Records what the openers and the reveal were asked, and answers as the test says.
    private final class Spy {
        var contactsOpened: [URL] = []
        var defaultOpened: [URL] = []
        var revealed: [URL] = []
        var reported: [String] = []
        var results: [Bool] = []
        var contactsAnswer = true
        var defaultAnswer = true
    }

    private func open(
        _ person: RichPerson, spy: Spy, directory: URL? = nil, now: Date = Date()
    ) {
        RichContactVCard.openInContacts(
            person, directory: directory ?? self.directory, now: now,
            openWithContacts: { url, done in spy.contactsOpened.append(url); done(spy.contactsAnswer) },
            openWithDefault: { url, done in spy.defaultOpened.append(url); done(spy.defaultAnswer) },
            reveal: { spy.revealed.append($0) },
            report: { spy.reported.append($0) },
            completion: { spy.results.append($0) })
    }

    func testOpenWritesTheCardToAVCardFileAndOpensItInContacts() throws {
        let spy = Spy()
        open(try person(), spy: spy)
        let url = try XCTUnwrap(spy.contactsOpened.first)
        XCTAssertEqual(spy.contactsOpened.count, 1)
        XCTAssertEqual(url.pathExtension, "vcf")
        let parsed = try XCTUnwrap(CNContactVCardSerialization.contacts(with: Data(contentsOf: url)).first)
        XCTAssertEqual(parsed.givenName, "Ada")
        XCTAssertEqual(parsed.emailAddresses.map { $0.value as String }, ["ada@example.com"])
        XCTAssertTrue(spy.defaultOpened.isEmpty, "Contacts took it: no second try")
        XCTAssertTrue(spy.revealed.isEmpty)
        XCTAssertEqual(spy.results, [true])
    }

    func testTheDefaultAppIsTriedWhenContactsRefuses() throws {
        let spy = Spy()
        spy.contactsAnswer = false
        open(try person(), spy: spy)
        XCTAssertEqual(spy.contactsOpened.count, 1)
        XCTAssertEqual(spy.defaultOpened, spy.contactsOpened, "the same file goes to the default app")
        XCTAssertTrue(spy.revealed.isEmpty)
        XCTAssertEqual(spy.results, [true])
    }

    func testFinderShowsTheFileWhenNoAppTakesIt() throws {
        let spy = Spy()
        spy.contactsAnswer = false
        spy.defaultAnswer = false
        open(try person(), spy: spy)
        XCTAssertEqual(spy.revealed, spy.contactsOpened)
        XCTAssertEqual(spy.revealed.map(\.pathExtension), ["vcf"])
        XCTAssertEqual(spy.results, [false])
        XCTAssertTrue(spy.reported.isEmpty, "the file exists; the user can open it from Finder")
    }

    func testAWriteFailureIsReportedAndNothingIsOpened() throws {
        // The "folder" is a regular file, so the folder cannot be made.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let spy = Spy()
        open(try person(), spy: spy, directory: blocker)
        XCTAssertEqual(spy.reported.count, 1)
        XCTAssertFalse(spy.reported[0].isEmpty, "the system's reason is shown")
        XCTAssertTrue(spy.contactsOpened.isEmpty && spy.defaultOpened.isEmpty && spy.revealed.isEmpty)
        XCTAssertEqual(spy.results, [false])
    }

    func testFileStaysInsideTheFolderWhateverTheName() throws {
        let spy = Spy()
        open(try person(name: "../../evil/ Name"), spy: spy)
        let url = try XCTUnwrap(spy.contactsOpened.first)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAVeryLongNameStaysWithinAFileNameLimit() throws {
        let long = String(repeating: "e\u{0301}\u{0302}\u{0303}", count: 70)   // 70 clusters, ~7 bytes each
        XCTAssertLessThanOrEqual(RichContactVCard.fileName(for: long).utf8.count, 200)
        let spy = Spy()
        open(try person(name: long), spy: spy)
        XCTAssertTrue(spy.reported.isEmpty, "writing works: \(spy.reported)")
        XCTAssertEqual(spy.contactsOpened.count, 1)
    }

    // MARK: Clean-up

    private func writeCard(_ name: String, age: TimeInterval, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("BEGIN:VCARD\nEND:VCARD\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testTheNextOpenRemovesCardsOlderThanAnHourAndKeepsNewerOnes() throws {
        let now = Date()
        let old = try writeCard("Old.vcf", age: 3_700, now: now)
        let recent = try writeCard("Recent.vcf", age: 600, now: now)
        let notACard = try writeCard("notes.txt", age: 9_000, now: now)
        open(try person(), spy: Spy(), now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "older than an hour: removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "newer: kept (Contacts may still read it)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notACard.path), "only .vcf files are touched")
    }

    func testTheCardIsNotRemovedRightAfterTheOpen() throws {
        let spy = Spy()
        open(try person(), spy: spy)
        let url = try XCTUnwrap(spy.contactsOpened.first)
        HostedTestSupport.settle(0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testQuitRemovesTheFolder() throws {
        let now = Date()
        _ = try writeCard("A.vcf", age: 10, now: now)
        _ = try writeCard("B.vcf", age: 10, now: now)
        RichContactVCard.removeAllFiles(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        RichContactVCard.removeAllFiles(in: directory)   // nothing there: harmless
    }

    func testContactsIsFoundByItsBundleIdentifier() {
        XCTAssertNotNil(NSWorkspace.shared.urlForApplication(withBundleIdentifier: RichContactVCard.contactsBundleIdentifier),
                        "the first choice for opening a card exists on this Mac")
    }
}
