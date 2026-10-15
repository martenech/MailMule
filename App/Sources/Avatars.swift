import AppKit
import Contacts
import Observation
import SwiftUI

/// Pictures for senders: the photo from Contacts, otherwise the company's logo (its website icon),
/// otherwise colored initials. Logos are cached on disk, one per domain.
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    /// Loaded pictures by key ("person:<address>" or "domain:<domain>"); NSNull means "none, use initials".
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    /// Logos are fetched from the internet only when allowed (Nastavenia → Súkromie).
    var loadsLogos = true

    private static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "Mailmule/Avatars", directoryHint: .isDirectory)
    }()

    /// Free mailboxes and mail services: their logo says nothing about the sender.
    static let personalDomains: Set<String> = AppModel.freeMailDomains.union([
        "icloud.com", "me.com", "mac.com", "yahoo.co.uk", "outlook.sk", "hotmail.sk", "seznam.sk",
    ])

    /// The picture for an address, starting a lookup the first time; nil while loading or when there is none.
    func image(for address: String) -> NSImage? {
        let address = address.lowercased()
        guard address.contains("@") else { return nil }
        let person = "person:" + address
        if let image = images[person] { return image }
        let domain = Self.organizationDomain(of: address)
        let company = domain.map { "domain:" + $0 }
        if let company, let image = images[company], missing.contains(person) { return image }
        if !loading.contains(person) && !missing.contains(person) {
            loading.insert(person)
            Task { await loadPerson(address, key: person, then: company.map { ($0, domain!) }) }
        }
        return nil
    }

    /// `noreply@e.blizzard.com` → `blizzard.com`; nil for personal mailboxes.
    static func organizationDomain(of address: String) -> String? {
        guard let host = address.split(separator: "@").last.map(String.init)?.lowercased() else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // Two-part public suffixes (co.uk, com.au…) keep three labels.
        let twoPart = ["co.uk", "org.uk", "com.au", "co.jp", "com.br", "co.nz", "com.pl", "com.cz"]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let domain = twoPart.contains(lastTwo) && labels.count >= 3 ? labels.suffix(3).joined(separator: ".") : lastTwo
        return personalDomains.contains(domain) ? nil : domain
    }

    // MARK: Loading

    private func loadPerson(_ address: String, key: String, then company: (key: String, domain: String)?) async {
        defer { loading.remove(key) }
        if let photo = await Self.contactPhoto(for: address) {
            images[key] = photo
            return
        }
        missing.insert(key)
        guard let company, images[company.key] == nil, !missing.contains(company.key), !loading.contains(company.key) else { return }
        loading.insert(company.key)
        defer { loading.remove(company.key) }
        if let logo = await logo(for: company.domain) {
            images[company.key] = logo
        } else {
            missing.insert(company.key)
        }
    }

    /// Photo of the contact with this address, if Contacts access was granted.
    private static func contactPhoto(for address: String) async -> NSImage? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let data: Data? = await Task.detached {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
            let contacts = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor])
            return contacts?.compactMap(\.thumbnailImageData).first
        }.value
        return data.flatMap(NSImage.init(data:))
    }

    /// The company's icon: from the disk cache, else its website's touch icon, else DuckDuckGo's icon service
    /// (which does not pass on who asked). Misses are remembered for a week.
    private func logo(for domain: String) async -> NSImage? {
        let file = Self.cacheDirectory.appending(path: domain + ".png")
        let miss = Self.cacheDirectory.appending(path: domain + ".none")
        if let image = NSImage(contentsOf: file) { return image }
        if let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 86_400 { return nil }
        guard loadsLogos else { return nil }
        let candidates = [
            "https://\(domain)/apple-touch-icon.png",
            "https://www.\(domain)/apple-touch-icon.png",
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
        ].compactMap(URL.init(string:))
        let session = URLSession(configuration: .ephemeral)
        for url in candidates {
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data),
                  let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
                  rep.pixelsWide >= 32 else { continue }
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
            return image
        }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        try? Data().write(to: miss)
        return nil
    }

    /// Forgets cached logos (Settings → Súkromie when logos are turned off).
    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        images = [:]
        missing = []
    }
}

/// A sender's picture: contact photo or company logo, otherwise initials on a color derived from the name.
struct SenderAvatar: View {
    let name: String
    var address: String?
    var emphasized = false
    var size: CGFloat = 34

    var body: some View {
        if let address, let image = AvatarStore.shared.image(for: address) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .background(Color.white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        } else {
            InitialsAvatar(name: name, emphasized: emphasized, size: size)
        }
    }
}
