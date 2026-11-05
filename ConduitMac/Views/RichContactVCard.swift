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

    static let contactsBundleIdentifier = "com.apple.AddressBook"

    /// A file holds a person's phone number and email address: it is removed an hour after it was written, on the
    /// next open at the latest, and the folder goes at quit. Not right after the open: Contacts may not have read
    /// the file yet.
    static let maximumAge: TimeInterval = 3_600

    /// Opens `url` and says whether that worked.
    typealias Opener = (URL, @escaping (Bool) -> Void) -> Void

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

    /// Writes the card to `<directory>/<name>.vcf` and opens it in Contacts. Order: Contacts itself, then the default
    /// app for vCards, then Finder shows the file so the user can open it by hand. A failure to write the file is
    /// reported to the user (`report`). `completion` gets true when an app took the file.
    static func openInContacts(
        _ person: RichPerson,
        directory: URL = defaultDirectory,
        now: Date = Date(),
        openWithContacts: @escaping Opener = systemOpenWithContacts,
        openWithDefault: @escaping Opener = systemOpenWithDefault,
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        report: (String) -> Void = showWriteFailure,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        removeStaleFiles(in: directory, now: now)
        let url = directory.appendingPathComponent("\(fileName(for: person.name)).vcf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try vCardData(for: person).write(to: url, options: .atomic)
        } catch {
            report(error.localizedDescription)
            completion(false)
            return
        }
        openWithContacts(url) { opened in
            if opened { completion(true); return }
            openWithDefault(url) { opened in
                if opened { completion(true); return }
                reveal(url)
                completion(false)
            }
        }
    }

    /// Contacts, named by bundle identifier (the user may have changed the default app for vCards). Not found, or
    /// refused: false.
    static let systemOpenWithContacts: Opener = { url, done in
        guard let contacts = NSWorkspace.shared.urlForApplication(withBundleIdentifier: contactsBundleIdentifier) else {
            done(false)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: contacts, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { done(error == nil) }
        }
    }

    static let systemOpenWithDefault: Opener = { url, done in
        done(NSWorkspace.shared.open(url))
    }

    /// The write failed (full disk, no temporary folder): the system's own reason under the action's name, which
    /// is already in the catalog.
    static let showWriteFailure: (String) -> Void = { reason in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Add to Contacts")
        alert.informativeText = reason
        alert.runModal()
    }

    /// Removes the cards older than `maximumAge`. Only `.vcf` files in `directory` are touched.
    static func removeStaleFiles(in directory: URL, now: Date = Date(), fileManager: FileManager = .default) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "vcf" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) >= maximumAge {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Quit: the whole folder goes.
    static func removeAllFiles(in directory: URL = defaultDirectory, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }

    /// The card's name as a file name: letters, digits, spaces, `-` and `_` only, so no name leaves the folder.
    static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard !cleaned.isEmpty else { return "Contact" }
        // At most 80 characters and well inside the 255 bytes of a file name, whatever the scripts.
        var name = String(cleaned.prefix(80))
        while name.utf8.count > 200 { name.removeLast() }
        return name
    }
}
