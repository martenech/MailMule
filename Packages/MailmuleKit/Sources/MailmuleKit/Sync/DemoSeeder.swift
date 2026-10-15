import Foundation

/// A made-up message for demo mode (README screenshots): stored and indexed like synced mail,
/// without any server.
public struct DemoMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress] = []
    public var subject: String
    public var markdown: String
    public var date: Date
    public var role: MailboxRole = .inbox
    public var seen = true
    public var flagged = false
    public var labels: [String] = []
    /// Index of the earlier message (in the same list) this one answers.
    public var replyTo: Int?
    public var attachments: [OutgoingAttachment] = []
    /// iCalendar text (METHOD:REQUEST) for an invitation.
    public var calendar: String?

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], subject: String, markdown: String,
                date: Date, role: MailboxRole = .inbox, seen: Bool = true, flagged: Bool = false, labels: [String] = [],
                replyTo: Int? = nil, attachments: [OutgoingAttachment] = [], calendar: String? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.markdown = markdown
        self.date = date
        self.role = role
        self.seen = seen
        self.flagged = flagged
        self.labels = labels
        self.replyTo = replyTo
        self.attachments = attachments
        self.calendar = calendar
    }
}

extension AccountService {
    /// Stores the messages as if they had been synced; returns each message's thread ID and key (same order).
    @discardableResult
    public func seedDemo(_ messages: [DemoMessage]) async throws -> [(threadID: String, key: String)] {
        var messageIDs: [String] = []
        var references: [[String]] = []
        var threadIDs: [String] = []
        var keys: [String] = []
        var nextUID: [MailboxRole: UInt32] = [:]
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "example.com"
        for (number, demo) in messages.enumerated() {
            var draft = Draft(from: demo.from, to: demo.to, cc: demo.cc, subject: demo.subject, markdown: demo.markdown,
                              attachments: demo.attachments)
            var chain: [String] = []
            if let parent = demo.replyTo, messageIDs.indices.contains(parent) {
                chain = references[parent] + [messageIDs[parent]]
                draft.inReplyTo = messageIDs[parent]
                draft.references = chain
            }
            draft.calendarReply = demo.calendar
            let messageID = "demo-\(number)-\(account.id)@\(domain)"
            var data = MessageBuilder.build(draft, date: demo.date, messageID: messageID).data
            if demo.calendar != nil {
                // An invitation, not an answer to one.
                data = Data(String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "method=REPLY", with: "method=REQUEST").utf8)
            }
            let key = messageKey(messageID)
            try vault.storeRaw(data, account: account.id, key: key)
            var flags: [String] = []
            if demo.seen { flags.append("\\Seen") }
            if demo.flagged { flags.append("\\Flagged") }
            let message = try makeStoredMessage(key: key, threadID: nil, flags: flags, labels: demo.labels)
            try await index.upsert(message)
            let uid = (nextUID[demo.role] ?? 1)
            nextUID[demo.role] = uid + 1
            let mailbox = switch demo.role {
            case .inbox: "INBOX"
            case .sent: "Sent"
            case .archive: "Archive"
            case .trash: "Trash"
            default: "Demo"
            }
            try await index.addMembership(account: account.id, mailbox: mailbox, role: demo.role, uid: uid, key: key)
            if demo.calendar != nil { try await indexEvent(of: message) }
            messageIDs.append(messageID)
            references.append(chain)
            threadIDs.append(message.threadID)
            keys.append(key)
        }
        try await writeThreadFiles(Set(threadIDs))
        return Array(zip(threadIDs, keys)).map { (threadID: $0.0, key: $0.1) }
    }
}
