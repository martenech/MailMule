import Contacts
import MailmuleKit
import Observation
import SwiftUI

/// Addresses for autocomplete: people from your mail (ranked by how often and how recently you wrote
/// to them) plus the macOS Contacts.
@MainActor
@Observable
final class AddressBook {
    struct Candidate: Identifiable, Hashable {
        var id: String { address.lowercased() }
        let name: String?
        let address: String
        let fromContacts: Bool
        let score: Double

        /// `"Ján Novák" <jan@example.sk>`, as written into the To/Cc field.
        var fieldValue: String {
            name.map { "\"\($0)\" <\(address)>" } ?? address
        }
    }

    private var history: [AddressSuggestion] = []
    private var contacts: [(name: String, address: String)] = []
    private(set) var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    private var loadedContacts = false

    func load(index: MailIndex, ownAddresses: [String], contacts includeContacts: Bool) async {
        history = (try? await index.addressSuggestions(ownAddresses: ownAddresses)) ?? []
        if includeContacts {
            await loadContacts()
        } else {
            contacts = []
            loadedContacts = false
        }
    }

    /// Asks for Contacts access once (macOS shows its permission prompt) and reads all e-mail addresses.
    private func loadContacts() async {
        guard !loadedContacts else { return }
        if contactsStatus == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        }
        guard contactsStatus == .authorized else { return }
        loadedContacts = true
        contacts = await Task.detached {
            var result: [(String, String)] = []
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactEmailAddressesKey] as [CNKeyDescriptor]
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let name = person.isEmpty ? contact.organizationName : person
                for email in contact.emailAddresses {
                    result.append((name, email.value as String))
                }
            }
            return result
        }.value.map { (name: $0.0, address: $0.1) }
    }

    /// Best matches for what is being typed: the name (any word) or the address, ignoring case and diacritics.
    func suggestions(for query: String, excluding: Set<String>, limit: Int = 6) -> [Candidate] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }

        func matches(_ name: String?, _ address: String) -> Bool {
            if Self.fold(address).contains(needle) { return true }
            guard let name else { return false }
            let folded = Self.fold(name)
            return folded.hasPrefix(needle) || folded.split(separator: " ").contains { $0.hasPrefix(needle) }
        }

        var byAddress: [String: Candidate] = [:]
        for item in history where matches(item.name, item.address) {
            byAddress[item.address.lowercased()] = Candidate(name: item.name?.nonEmpty, address: item.address,
                                                             fromContacts: false, score: item.score)
        }
        for contact in contacts where matches(contact.name, contact.address) {
            let key = contact.address.lowercased()
            let existing = byAddress[key]
            // Contacts are people you chose to keep: rank them up and prefer their name.
            byAddress[key] = Candidate(name: contact.name.nonEmpty ?? existing?.name, address: contact.address,
                                       fromContacts: true, score: (existing?.score ?? 0) + 5)
        }
        return byAddress.values
            .filter { !excluding.contains($0.address.lowercased()) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
