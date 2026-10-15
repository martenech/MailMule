import CryptoKit
import Foundation

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var email: String
    public var username: String
    public var imapHost: String
    public var imapPort: UInt16
    public var smtpHost: String
    public var smtpPort: UInt16
    public var imapSecurity: ConnectionSecurity
    public var smtpSecurity: ConnectionSecurity

    public init(name: String, email: String, username: String? = nil,
                imapHost: String, imapPort: UInt16 = 993, smtpHost: String, smtpPort: UInt16 = 465,
                imapSecurity: ConnectionSecurity? = nil, smtpSecurity: ConnectionSecurity? = nil) {
        self.id = Account.slug(email)
        self.name = name
        self.email = email
        self.username = username ?? email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.imapSecurity = imapSecurity ?? .forPort(imapPort)
        self.smtpSecurity = smtpSecurity ?? .forPort(smtpPort)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, email, username, imapHost, imapPort, smtpHost, smtpPort, imapSecurity, smtpSecurity
    }

    /// Accounts saved before the security choice existed get it from their ports.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        username = try c.decode(String.self, forKey: .username)
        imapHost = try c.decode(String.self, forKey: .imapHost)
        imapPort = try c.decode(UInt16.self, forKey: .imapPort)
        smtpHost = try c.decode(String.self, forKey: .smtpHost)
        smtpPort = try c.decode(UInt16.self, forKey: .smtpPort)
        imapSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .imapSecurity) ?? .forPort(imapPort)
        smtpSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .smtpSecurity) ?? .forPort(smtpPort)
    }

    public static func gmail(name: String, email: String) -> Account {
        Account(name: name, email: email, imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
    }

    public var address: EmailAddress { EmailAddress(name: name, address: email) }

    static func slug(_ email: String) -> String {
        email.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }
}

public enum MailboxRole: String, Sendable {
    case inbox, sent, archive, trash
    /// Any other server folder.
    case folder
    /// Spam / Junk.
    case junk
    /// Snoozed threads waiting to come back to the inbox.
    case snoozed
}

/// A server folder shown in the sidebar.
public struct FolderInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Mailbox name on the server (modified UTF-7), used in commands.
    public let name: String
    /// Path components for display, decoded ("Klienti", "Novák").
    public let path: [String]
    public var displayName: String { path.last ?? name }
    public var depth: Int { max(0, path.count - 1) }
}

public struct StoredMessage: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var accountID: String
    public var messageID: String?
    public var threadID: String
    public var subject: String
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date
    public var snippet: String
    public var bodyText: String
    public var hasHTML: Bool
    public var seen: Bool
    public var flagged: Bool
    public var labels: [String]
    public var rawPath: String
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [String]
}

public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var accountID: String
    public var subject: String
    public var participants: [String]
    /// Lowercased sender addresses matching `participants`, to leave out your own.
    public var participantAddresses: [String] = []
    public var date: Date
    public var messageCount: Int
    public var unreadCount: Int
    public var snippet: String
    /// Sender of the latest message, for sorting and grouping by sender.
    public var latestSender: String = ""
    /// Address of that sender (for the avatar).
    public var latestSenderAddress: String = ""
    public var flagged: Bool = false
    public var hasAttachments: Bool = false
    /// User-visible tags (Gmail labels or IMAP keywords), without system labels.
    public var tags: [String] = []
    /// In a mailbox view: the thread has a newer message outside it, usually your own reply.
    public var hasLaterMessage = false
    /// Your message is the newest in the thread: you answered or forwarded it (icon in the list).
    public var lastAction: ThreadAction?

    public var isUnread: Bool { unreadCount > 0 }

    public init(id: String, accountID: String, subject: String, participants: [String], participantAddresses: [String] = [], date: Date,
                messageCount: Int, unreadCount: Int, snippet: String, latestSender: String = "", latestSenderAddress: String = "",
                hasLaterMessage: Bool = false, lastAction: ThreadAction? = nil, flagged: Bool = false, hasAttachments: Bool = false, tags: [String] = []) {
        self.id = id
        self.accountID = accountID
        self.subject = subject
        self.participants = participants
        self.participantAddresses = participantAddresses
        self.date = date
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.snippet = snippet
        self.latestSender = latestSender
        self.latestSenderAddress = latestSenderAddress
        self.hasLaterMessage = hasLaterMessage
        self.lastAction = lastAction
        self.flagged = flagged
        self.hasAttachments = hasAttachments
        self.tags = tags
    }
}

/// "Pripomenúť, ak neodpovie": the thread comes back to the inbox at `due` unless someone answers after `since`.
public struct FollowUp: Hashable, Sendable {
    public var threadID: String
    public var accountID: String
    public var due: Date
    public var since: Date
    /// The time passed without an answer and the thread was brought back.
    public var fired: Bool

    public init(threadID: String, accountID: String, due: Date, since: Date, fired: Bool) {
        self.threadID = threadID
        self.accountID = accountID
        self.due = due
        self.since = since
        self.fired = fired
    }
}

/// A meeting known from an invitation in the mail.
public struct StoredEvent: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var messageKey: String
    public var threadID: String
    public var accountID: String
    public var summary: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var isCancelled: Bool
}

/// Your mail with one person (person card).
public struct PersonStats: Equatable, Sendable {
    public var messages: Int
    public var threads: Int
    public var first: Date?
    public var last: Date?
    /// Their newest message to you, and your newest message (in a thread with them).
    public var lastFromThem: Date?
    public var lastToThem: Date?

    public init(messages: Int, threads: Int, first: Date?, last: Date?, lastFromThem: Date?, lastToThem: Date?) {
        self.messages = messages
        self.threads = threads
        self.first = first
        self.last = last
        self.lastFromThem = lastFromThem
        self.lastToThem = lastToThem
    }
}

public enum ThreadAction: Hashable, Sendable {
    case replied, forwarded
}

public enum ThreadFilter: Hashable, Sendable {
    case inbox
    case sent
    case archive
    case trash
    case all
    case starred
    case tag(String)
    /// A server folder by mailbox name.
    case folder(String)
    /// Spam of all accounts in scope.
    case junk
    /// Threads snoozed until a later time.
    case snoozed
    /// Threads waiting for an answer ("pripomenúť, ak neodpovie").
    case followUps
}

public enum AttachmentPolicy: String, Codable, CaseIterable, Sendable {
    /// Download whole messages.
    case always
    /// Download text and HTML only; attachments are fetched when needed.
    case onDemand
}

/// How much mail an account keeps locally.
public struct SyncPolicy: Codable, Equatable, Sendable {
    /// Months of history to download: nil = everything, 0 = only the newest messages of each folder.
    public var historyMonths: Int?
    public var attachments: AttachmentPolicy

    public init(historyMonths: Int? = nil, attachments: AttachmentPolicy = .always) {
        self.historyMonths = historyMonths
        self.attachments = attachments
    }

    /// Messages older than this are not downloaded (and removed locally when the limit shrinks).
    public var cutoff: Date? {
        guard let months = historyMonths, months > 0 else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: Date())
    }

    public var downloadsHistory: Bool { historyMonths != 0 }
}

/// Someone you have exchanged mail with, for address autocomplete.
public struct AddressSuggestion: Hashable, Sendable {
    public let address: String
    public let name: String?
    /// Messages you sent to them.
    public let sent: Int
    /// Messages they appear in at all.
    public let seen: Int
    public let lastSeen: Date

    public init(address: String, name: String?, sent: Int, seen: Int, lastSeen: Date) {
        self.address = address
        self.name = name
        self.sent = sent
        self.seen = seen
        self.lastSeen = lastSeen
    }

    /// Automated senders (noreply, notifications) rank below people.
    public var isAutomated: Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification", "mailer-daemon",
                "newsletter", "info", "support", "notify", "email-notice", "bounce"].contains { local.contains($0) }
    }

    /// Higher is better: people you write to, often and recently.
    public var score: Double {
        let days = max(0, Date().timeIntervalSince(lastSeen) / 86_400)
        let recency = 1 / (1 + days / 30)
        return (Double(sent) * 4 + Double(seen)) * (0.5 + recency) * (isAutomated ? 0.1 : 1)
    }
}

/// How the thread list is ordered.
public enum ThreadSort: String, Codable, CaseIterable, Sendable {
    case newest, oldest, sender, subject, unreadFirst
}

/// View options of the thread list, applied in the index query so they cover all mail, not just the newest page.
public struct ThreadListOptions: Codable, Equatable, Sendable {
    public var sort: ThreadSort = .newest
    public var unreadOnly = false
    public var attachmentsOnly = false
    public var starredOnly = false

    public init(sort: ThreadSort = .newest, unreadOnly: Bool = false, attachmentsOnly: Bool = false, starredOnly: Bool = false) {
        self.sort = sort
        self.unreadOnly = unreadOnly
        self.attachmentsOnly = attachmentsOnly
        self.starredOnly = starredOnly
    }

    private enum CodingKeys: String, CodingKey { case sort, unreadOnly, attachmentsOnly, starredOnly }

    /// Tolerates settings saved before a field existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = (try? c.decode(ThreadSort.self, forKey: .sort)) ?? .newest
        unreadOnly = (try? c.decode(Bool.self, forKey: .unreadOnly)) ?? false
        attachmentsOnly = (try? c.decode(Bool.self, forKey: .attachmentsOnly)) ?? false
        starredOnly = (try? c.decode(Bool.self, forKey: .starredOnly)) ?? false
    }
}

public enum Tags {
    /// Labels that are mail-system state rather than user tags (Gmail `\Inbox`, IMAP `$Forwarded`, junk markers).
    public static func isUserTag(_ label: String) -> Bool {
        !(label.hasPrefix("\\") || label.hasPrefix("$")
          || ["junk", "nonjunk", "notjunk", "odložené", "snoozed"].contains(label.lowercased()))
    }

    /// Key for comparing tags: "Práca" and "práca" are the same tag, "Praca" is a different one.
    public static func fold(_ tag: String) -> String {
        tag.lowercased()
    }

    /// User tags from IMAP flags: keywords (no backslash) decoded from modified UTF-7.
    public static func fromKeywords(_ flags: [String]) -> [String] {
        flags.filter { !$0.hasPrefix("\\") }.filter(isUserTag).map(ModifiedUTF7.tag(forKeyword:))
    }
}

enum Hashing {
    static func hex(_ string: String, length: Int = 24) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

extension String {
    /// Subject without "Re:", "Fwd:", "AW:", "Odp:" prefixes.
    public var baseSubject: String {
        var s = trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?i)(re|fw|fwd|aw|wg|odp|sv|vs)(\[\d+\])?\s*:\s*"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s
    }
}
