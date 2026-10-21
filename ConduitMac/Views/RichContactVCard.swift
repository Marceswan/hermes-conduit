import AppKit
import Contacts

// Mac twin of RichNewContactSheet in Conduit/Cards/RichMediaCardViews.swift (R3, Ruling R23); keep in sync
// (PORTING_LEDGER). CNContactViewController(forNewContact:) is not in the macOS SDK, so the card becomes a vCard that
// Contacts opens. Contacts asks the user to confirm; Conduit needs no contacts permission.
enum RichContactVCard {
    /// Where the vCard files go: one folder in the temporary directory. A file is replaced by the next card with the
    /// same name.
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ConduitContactCards", isDirectory: true)
    }

    /// The same fields the iOS sheet fills in: name (first word is the given name), job title, phone, email, website.
    static func contact(for person: RichPerson) -> CNMutableContact {
        let contact = CNMutableContact()
        let parts = person.name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? person.name
        if parts.count > 1 { contact.familyName = parts[1] }
        if let detail = person.detail { contact.jobTitle = detail }
        if let phone = person.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = person.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }
        if let url = person.url {
            contact.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: url.absoluteString as NSString)]
        }
        return contact
    }

    static func vCardData(for person: RichPerson) throws -> Data {
        try CNContactVCardSerialization.data(with: [contact(for: person)])
    }

    /// Writes the card to `<directory>/<name>.vcf` and hands the file to `open` (Contacts, by default). When the file
    /// cannot be written or `open` refuses it, the file is shown in Finder when it exists, so the user can open it
    /// by hand. True when `open` took the file.
    @discardableResult
    static func openInContacts(
        _ person: RichPerson,
        directory: URL = defaultDirectory,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) -> Bool {
        let url = directory.appendingPathComponent("\(fileName(for: person.name)).vcf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try vCardData(for: person).write(to: url, options: .atomic)
        } catch {
            return false
        }
        if open(url) { return true }
        reveal(url)
        return false
    }

    /// The card's name as a file name: letters, digits, spaces, `-` and `_` only, so no name leaves the folder.
    static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return cleaned.isEmpty ? "Contact" : String(cleaned.prefix(80))
    }
}
