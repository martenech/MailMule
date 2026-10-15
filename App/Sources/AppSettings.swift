import Foundation
import MailmuleKit
import OSLog
import Security
import SwiftUI

struct AppSettings: Codable, Equatable {
    var accounts: [Account] = []
    /// Your own name for an account ("Práca", "Firma"), shown instead of the address; by account ID.
    var accountLabels: [String: String] = [:]
    var mailVaultPath = "~/Mail"
    var obsidianVaultPath = ""
    var obsidianFolder = "Mail"
    var openInObsidianAfterExport = true
    /// Superhuman-style: sending a reply from the Inbox archives the thread (it comes back when someone answers).
    var archiveOnReply = true
    /// Markdown signature per account ID; added to new messages, replies and forwards.
    var signatures: [String: String] = [:]
    /// Senders (lowercased addresses) whose mail loads images from the internet automatically.
    var trustedImageSenders: [String] = []
    /// Load images from the internet in every message (otherwise only after "Načítať obrázky").
    var loadRemoteImages = false
    /// Drop tracking pixels (1×1 and known open-tracking URLs) whenever internet images are loaded.
    var blockTrackers = true
    /// Finder color numbers the user picked for tags in Mailmule; other tags use Finder's color.
    var tagColors: [String: Int] = [:]
    /// How much mail each account keeps locally (history limit, attachments on demand).
    var syncPolicies: [String: SyncPolicy] = [:]

    // Accounts
    /// Accounts that are not synced (no connection, no notifications); their mail stays visible.
    var disabledAccounts: [String] = []
    /// Sender for new messages when no account is selected; also listed first.
    var primaryAccountID: String?
    var defaultSender: DefaultSender = .currentAccount
    /// Full sync of all folders; new inbox mail arrives right away through IDLE regardless.
    var syncIntervalMinutes = 5
    var suggestFromContacts = true

    // Compose
    var messageFormat: MessageFormat = .formatted
    var editorFontSize: Double = 14
    /// Spell checking language code, or "auto" to detect it.
    var spellingLanguage = "auto"
    var signaturePlacement: SignaturePlacement = .all
    /// Seconds a sent message waits and can be taken back ("Vrátiť"); 0 sends right away.
    var undoSendSeconds = 10
    /// New messages and replies open in their own window instead of a sheet over the main window.
    var composeInWindow = false

    // Message list
    var showPreview = true
    var previewLines = 1
    var largeAvatars = false
    var rowSpacing: RowSpacing = .normal
    /// Sidebar, list and message; false hides the sidebar (it can still be shown from the toolbar).
    var threeColumns = true

    // Notifications
    var notifyBanners = true
    var notifySound = true
    var dockBadge = true
    var notifyPreview = true
    var notifyOnlyVIP = false
    /// Lowercased addresses or "@domain" entries.
    var vipSenders: [String] = []
    var quietHours = false
    /// Minutes after midnight.
    var quietFrom = 22 * 60
    var quietTo = 7 * 60
    var mutedAccounts: [String] = []
    /// Notification sound per account ID: a system sound name, "" for the default, "none" for silence.
    var accountSounds: [String: String] = [:]

    // Privacy
    var warnSuspicious = true
    /// Newsletters left with "Odhlásiť z odberu": lowercased sender address → when.
    var unsubscribed: [String: Date] = [:]
    /// Company logos as sender pictures, fetched once per domain from its website.
    var senderLogos = true
    /// Your answers to meeting invitations by event UID (ACCEPTED, TENTATIVE, DECLINED).
    var inviteResponses: [String: String] = [:]
    /// Events already added to Calendar by UID, so a second click does not duplicate them.
    var calendarAdded: [String] = []
    /// Events from the Mac's Calendar app on Prehľad (needs full calendar access).
    var calendarConnected = false
    /// Calendars left out (new calendars show up by default).
    var calendarHidden: [String] = []
    /// Accepted invitations are added to Calendar.
    var addAcceptedToCalendar = true

    /// Searches kept in the sidebar ("Hľadania").
    var savedSearches: [SavedSearch] = []

    // Prehľad (home)
    /// Visible cards in order (`HomeWidget` raw values).
    var homeWidgets: [String] = HomeWidget.defaultOrder.map(\.rawValue)
    var homeGreeting = true
    var homeName = ""
    var homeQuote = true
    var homeNotes = ""
    var openHomeOnLaunch = true
    /// Invitations in mail stored before events were indexed have been looked through.
    var eventsBackfilled = false

    // Assistant (local language model)
    var assistantEnabled = true
    var assistantModel: LocalModel.Choice = .qwen35_4b

    // Rules and automation
    var rules: [MailRule] = []
    var swipeLeading: SwipeAction = .archive
    var swipeTrailing: SwipeAction = .star
    /// Archiving (by hand or by a rule) also marks the thread as read.
    var markReadOnArchive = false
    /// Changed single-key shortcuts: action → key ("" = off). Missing actions use their default keys.
    var shortcuts: [String: String] = [:]

    var mailVaultURL: URL {
        URL(fileURLWithPath: (mailVaultPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    var obsidianVaultURL: URL? {
        obsidianVaultPath.isEmpty ? nil : URL(fileURLWithPath: (obsidianVaultPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Folders under the home directory that contain `.obsidian`, i.e. Obsidian vaults.
    static func detectObsidianVaults() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home, home.appending(path: "Documents"), home.appending(path: "Obsidian"),
                          home.appending(path: "Library/Mobile Documents/iCloud~md~obsidian/Documents")]
        var vaults: [String] = []
        for parent in candidates {
            guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for child in children where FileManager.default.fileExists(atPath: child.appending(path: ".obsidian").path) {
                vaults.append((child.path as NSString).abbreviatingWithTildeInPath)
            }
        }
        return vaults
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case accounts, accountLabels, mailVaultPath, obsidianVaultPath, obsidianFolder, openInObsidianAfterExport, tagColors, syncPolicies,
             archiveOnReply, signatures, trustedImageSenders, loadRemoteImages, blockTrackers,
             disabledAccounts, primaryAccountID, defaultSender, syncIntervalMinutes, suggestFromContacts,
             messageFormat, editorFontSize, spellingLanguage, signaturePlacement, undoSendSeconds, composeInWindow,
             showPreview, previewLines, largeAvatars, rowSpacing, threeColumns,
             notifyBanners, notifySound, dockBadge, notifyPreview, notifyOnlyVIP, vipSenders,
             quietHours, quietFrom, quietTo, mutedAccounts, accountSounds, warnSuspicious, unsubscribed, senderLogos, inviteResponses, calendarAdded,
             calendarConnected, calendarHidden, addAcceptedToCalendar,
             rules, swipeLeading, swipeTrailing, markReadOnArchive, assistantEnabled, assistantModel, shortcuts,
             savedSearches, homeWidgets, homeGreeting, homeName, homeQuote, homeNotes, openHomeOnLaunch, eventsBackfilled
    }

    /// Every field is optional, so settings saved by an older version still load (and keep the accounts).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        accountLabels = value(.accountLabels, d.accountLabels)
        mailVaultPath = value(.mailVaultPath, d.mailVaultPath)
        obsidianVaultPath = value(.obsidianVaultPath, d.obsidianVaultPath)
        obsidianFolder = value(.obsidianFolder, d.obsidianFolder)
        openInObsidianAfterExport = value(.openInObsidianAfterExport, d.openInObsidianAfterExport)
        tagColors = value(.tagColors, d.tagColors)
        syncPolicies = value(.syncPolicies, d.syncPolicies)
        archiveOnReply = value(.archiveOnReply, d.archiveOnReply)
        signatures = value(.signatures, d.signatures)
        trustedImageSenders = value(.trustedImageSenders, d.trustedImageSenders)
        loadRemoteImages = value(.loadRemoteImages, d.loadRemoteImages)
        blockTrackers = value(.blockTrackers, d.blockTrackers)
        disabledAccounts = value(.disabledAccounts, d.disabledAccounts)
        primaryAccountID = value(.primaryAccountID, d.primaryAccountID)
        defaultSender = value(.defaultSender, d.defaultSender)
        syncIntervalMinutes = value(.syncIntervalMinutes, d.syncIntervalMinutes)
        suggestFromContacts = value(.suggestFromContacts, d.suggestFromContacts)
        messageFormat = value(.messageFormat, d.messageFormat)
        editorFontSize = value(.editorFontSize, d.editorFontSize)
        spellingLanguage = value(.spellingLanguage, d.spellingLanguage)
        signaturePlacement = value(.signaturePlacement, d.signaturePlacement)
        undoSendSeconds = value(.undoSendSeconds, d.undoSendSeconds)
        composeInWindow = value(.composeInWindow, d.composeInWindow)
        showPreview = value(.showPreview, d.showPreview)
        previewLines = value(.previewLines, d.previewLines)
        largeAvatars = value(.largeAvatars, d.largeAvatars)
        rowSpacing = value(.rowSpacing, d.rowSpacing)
        threeColumns = value(.threeColumns, d.threeColumns)
        notifyBanners = value(.notifyBanners, d.notifyBanners)
        notifySound = value(.notifySound, d.notifySound)
        dockBadge = value(.dockBadge, d.dockBadge)
        notifyPreview = value(.notifyPreview, d.notifyPreview)
        notifyOnlyVIP = value(.notifyOnlyVIP, d.notifyOnlyVIP)
        vipSenders = value(.vipSenders, d.vipSenders)
        quietHours = value(.quietHours, d.quietHours)
        quietFrom = value(.quietFrom, d.quietFrom)
        quietTo = value(.quietTo, d.quietTo)
        mutedAccounts = value(.mutedAccounts, d.mutedAccounts)
        accountSounds = value(.accountSounds, d.accountSounds)
        warnSuspicious = value(.warnSuspicious, d.warnSuspicious)
        unsubscribed = value(.unsubscribed, d.unsubscribed)
        senderLogos = value(.senderLogos, d.senderLogos)
        inviteResponses = value(.inviteResponses, d.inviteResponses)
        calendarAdded = value(.calendarAdded, d.calendarAdded)
        calendarConnected = value(.calendarConnected, d.calendarConnected)
        calendarHidden = value(.calendarHidden, d.calendarHidden)
        addAcceptedToCalendar = value(.addAcceptedToCalendar, d.addAcceptedToCalendar)
        rules = value(.rules, d.rules)
        swipeLeading = value(.swipeLeading, d.swipeLeading)
        swipeTrailing = value(.swipeTrailing, d.swipeTrailing)
        markReadOnArchive = value(.markReadOnArchive, d.markReadOnArchive)
        assistantEnabled = value(.assistantEnabled, d.assistantEnabled)
        assistantModel = value(.assistantModel, d.assistantModel)
        shortcuts = value(.shortcuts, d.shortcuts)
        savedSearches = value(.savedSearches, d.savedSearches)
        homeWidgets = value(.homeWidgets, d.homeWidgets)
        homeGreeting = value(.homeGreeting, d.homeGreeting)
        homeName = value(.homeName, d.homeName)
        homeQuote = value(.homeQuote, d.homeQuote)
        homeNotes = value(.homeNotes, d.homeNotes)
        openHomeOnLaunch = value(.openHomeOnLaunch, d.openHomeOnLaunch)
        eventsBackfilled = value(.eventsBackfilled, d.eventsBackfilled)
    }
}

/// A search kept in the sidebar: a name and the query with operators ("od:faktury má:prílohu").
struct SavedSearch: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
}

/// What a swipe on a thread in the list does.
enum SwipeAction: String, Codable, CaseIterable {
    case none, archive, delete, star, read, snooze

    var title: String {
        switch self {
        case .none: "Nič"
        case .archive: "Archivovať"
        case .delete: "Odstrániť"
        case .star: "Označiť hviezdičkou"
        case .read: "Prečítané / neprečítané"
        case .snooze: "Odložiť"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .archive: "archivebox"
        case .delete: "trash"
        case .star: "star"
        case .read: "envelope.open"
        case .snooze: "clock"
        }
    }
}

enum DefaultSender: String, Codable, CaseIterable {
    /// The account selected in the sidebar, otherwise the primary one.
    case currentAccount
    case primary
}

enum MessageFormat: String, Codable, CaseIterable {
    /// HTML rendered from Markdown plus a plain text part.
    case formatted
    /// Plain text only.
    case plain
}

enum SignaturePlacement: String, Codable, CaseIterable {
    case all, newAndReplies, newOnly, never

    var title: String {
        switch self {
        case .all: "Nových správach, odpovediach aj preposlaniach"
        case .newAndReplies: "Nových správach a odpovediach"
        case .newOnly: "Len v nových správach"
        case .never: "Nikdy"
        }
    }
}

enum RowSpacing: String, Codable, CaseIterable {
    case tight, normal, relaxed

    var title: String {
        switch self {
        case .tight: "Tesné"
        case .normal: "Normálne"
        case .relaxed: "Voľné"
        }
    }

    var padding: CGFloat {
        switch self {
        case .tight: 4
        case .normal: 7
        case .relaxed: 11
        }
    }
}

enum Keychain {
    private static let service = "app.mailmule"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            Logger(subsystem: "app.mailmule.Mailmule", category: "keychain")
                .error("password for \(account, privacy: .public) failed: \(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "", privacy: .public)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func setPassword(_ password: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Items saved by builds with a temporary signature trust only that exact build, so macOS asks again
    /// after every update. Saving the password again from the Apple-signed app makes it the item's owner,
    /// and later builds signed by the same team read it without asking.
    static func adoptIfNeeded(_ password: String, for account: String) {
        let key = "keychainAdopted.\(account)"
        guard !UserDefaults.standard.bool(forKey: key), isSignedByAppleDeveloper else { return }
        setPassword(password, for: account)
        UserDefaults.standard.set(true, forKey: key)
    }

    private static var isSignedByAppleDeveloper: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
