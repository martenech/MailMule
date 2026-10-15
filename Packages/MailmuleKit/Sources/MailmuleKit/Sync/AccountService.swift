import Foundation
import OSLog

let syncLog = Logger(subsystem: "app.mailmule.Mailmule", category: "sync")

public struct SendResult: Sendable {
    public var threadID: String
    /// The sent message, for `copyToSent` (done separately so the window does not wait for the server).
    public var raw: Data
}

public struct SyncReport: Sendable {
    public var mailboxes: [String] = []
    public var sentMailbox: String?
    public var newMessages = 0
    /// Older messages not downloaded yet (fetched by `backfill`).
    public var remainingHistory = 0
    /// Custom server folders (not Inbox/Sent/Archive/Trash/Drafts); empty for Gmail, whose labels are tags.
    public var folders: [FolderInfo] = []
    /// New unread messages that arrived in INBOX, for notifications.
    public var newInboxMessages: [StoredMessage] = []
    /// How long each step took ("INBOX 0,4 s"), for the log.
    public var timings: [String] = []
    /// Mailboxes left out because nothing changed in them.
    public var skippedMailboxes = 0
    /// Only the inbox was looked at (after IDLE); mailbox and folder lists are not filled in.
    public var inboxOnly = false
    public var changedThreads: Set<String> = []
}

/// Owns the IMAP connection of one account: syncs mailboxes into the vault and performs actions.
/// Being an actor, it runs one server operation at a time.
public actor AccountService {
    public nonisolated let account: Account
    private let password: String
    let index: MailIndex
    let vault: MailVault
    private let windowSize: Int

    private var client: IMAPClient
    private var mailboxes: [IMAPMailbox] = []

    private var policy: SyncPolicy

    public init(account: Account, password: String, index: MailIndex, vault: MailVault,
                policy: SyncPolicy = .init(), windowSize: Int = 300) {
        self.policy = policy
        self.account = account
        self.password = password
        self.index = index
        self.vault = vault
        self.windowSize = windowSize
        client = IMAPClient(host: account.imapHost, port: account.imapPort, username: account.username, password: password,
                                security: account.imapSecurity)
    }

    public func setPolicy(_ policy: SyncPolicy) async {
        self.policy = policy
        // A different history limit changes which messages belong locally; look at every mailbox again.
        try? await index.clearMailboxSnapshots(account: account.id)
    }

    // MARK: - Sync

    public func sync() async throws -> SyncReport {
        syncLog.notice("\(self.account.email, privacy: .public): sync start")
        defer { syncLog.notice("\(self.account.email, privacy: .public): sync end") }
        return try await withClient { client in
            var report = SyncReport()
            // Re-list every time so folders created elsewhere show up.
            self.mailboxes = try await client.listMailboxes()
            let gmail = await client.isGmail
            report.mailboxes = self.mailboxes.map(\.name)
            report.sentMailbox = self.sentMailbox?.name
            report.folders = gmail ? [] : self.customFolders.map(self.folderInfo)
            for (name, role) in self.syncedMailboxes(gmail: gmail) {
                let start = ContinuousClock.now
                try await self.syncMailbox(name, role: role, client: client, report: &report)
                report.timings.append("\(ModifiedUTF7.decode(name)) \(Self.seconds(since: start))")
            }
            syncLog.notice("\(self.account.email, privacy: .public): writing \(report.changedThreads.count) notes")
            let start = ContinuousClock.now
            try await self.writeThreadFiles(report.changedThreads)
            report.timings.append("poznámky \(Self.seconds(since: start))")
            return report
        }
    }

    /// Syncs just the inbox: what IDLE reports is new inbox mail, so the other folders can wait for the next full sync.
    public func syncInbox() async throws -> SyncReport {
        try await withClient { client in
            var report = SyncReport()
            report.inboxOnly = true
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let gmail = await client.isGmail
            for (name, role) in self.syncedMailboxes(gmail: gmail) where role == .inbox {
                let start = ContinuousClock.now
                try await self.syncMailbox(name, role: role, client: client, report: &report)
                report.timings.append("\(ModifiedUTF7.decode(name)) \(Self.seconds(since: start))")
            }
            try await self.writeThreadFiles(report.changedThreads)
            return report
        }
    }

    /// Downloads up to `batch` older messages (newest first, across all synced folders).
    /// `remainingHistory` in the result tells how many are still missing.
    public func backfill(batch: Int = 200) async throws -> SyncReport {
        try await withClient { client in
            var report = SyncReport()
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let gmail = await client.isGmail
            var budget = batch
            for (name, role) in self.syncedMailboxes(gmail: gmail) {
                let before = report.newMessages
                try await self.syncMailbox(name, role: role, client: client, report: &report,
                                           backfill: budget, refreshFlags: false)
                budget = max(0, budget - (report.newMessages - before))
            }
            try await self.writeThreadFiles(report.changedThreads)
            return report
        }
    }

    /// The folders Mailmule syncs, in sync order.
    private func syncedMailboxes(gmail: Bool) -> [(String, MailboxRole)] {
        var list: [(String, MailboxRole)] = [("INBOX", .inbox)]
        if let sent = sentMailbox { list.append((sent.name, .sent)) }
        // Archive and Trash are only synced when they exist; they are created on first use.
        if let archive = gmail ? mailbox(withAttribute: "\\all") : mailbox(attribute: "\\archive", names: Self.archiveNames) {
            list.append((archive.name, .archive))
        }
        if !gmail {
            list += customFolders.map { ($0.name, .folder) }
        }
        if let junk = junkMailbox { list.append((junk.name, .junk)) }
        if let snoozed = snoozedMailbox { list.append((snoozed.name, .snoozed)) }
        if let trash = mailbox(attribute: "\\trash", names: Self.trashNames) { list.append((trash.name, .trash)) }
        return list
    }

    private var junkMailbox: IMAPMailbox? {
        mailbox(attribute: "\\junk", names: ["Spam", "Junk", "Junk E-mail", "Nevyžiadaná pošta", "Nevyžiadané"])
    }

    /// Creates a server folder (next to INBOX's children on "INBOX."-namespace servers) and syncs.
    public func createFolder(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            _ = try await self.ensureMailbox(attribute: "\\none", names: [trimmed],
                                             create: ModifiedUTF7.encode(trimmed), client: client)
        }
        _ = try await sync()
    }

    /// Server folders other than the special ones.
    private var customFolders: [IMAPMailbox] {
        let special = Set([sentMailbox, mailbox(attribute: "\\archive", names: Self.archiveNames),
                           mailbox(attribute: "\\trash", names: Self.trashNames),
                           mailbox(attribute: "\\drafts", names: ["Drafts", "Koncepty", "Concepts"]), junkMailbox, snoozedMailbox]
            .compactMap { $0?.name })
        return mailboxes.filter { box in
            box.name.uppercased() != "INBOX" && !special.contains(box.name)
                && !box.has("\\noselect") && !box.has("\\nonexistent")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func folderInfo(_ box: IMAPMailbox) -> FolderInfo {
        var components = box.delimiter.flatMap { $0.isEmpty ? nil : box.name.components(separatedBy: $0) } ?? [box.name]
        // "INBOX.Klienti" is shown as "Klienti".
        if components.count > 1, components.first?.uppercased() == "INBOX" { components.removeFirst() }
        return FolderInfo(name: box.name, path: components.map(ModifiedUTF7.decode))
    }

    /// Moves a thread's messages into any server folder (custom folders, or Inbox/Archive/Trash by name).
    public func moveThread(_ threadID: String, toMailbox target: String) async throws {
        let copies = try await index.allUIDs(inThread: threadID).filter { $0.role != .sent && $0.mailbox != target }
        guard !copies.isEmpty else { return }
        try await withClient { client in
            for (mailbox, items) in Dictionary(grouping: copies, by: \.mailbox) {
                try await client.uidMove(in: mailbox, uids: items.map(\.uid), to: target)
                try await self.index.removeMembership(account: self.account.id, mailbox: mailbox, uids: items.map(\.uid))
            }
        }
        _ = try await sync()
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f s", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    private func syncMailbox(_ mailbox: String, role: MailboxRole, client: IMAPClient, report: inout SyncReport,
                             backfill: Int = 0, refreshFlags: Bool = true) async throws {
        syncLog.notice("\(self.account.email, privacy: .public): select \(mailbox, privacy: .public)")
        let info = try await client.select(mailbox)
        if let stored = try await index.uidValidity(account: account.id, mailbox: mailbox), stored != info.uidValidity {
            try await index.clearMembership(account: account.id, mailbox: mailbox)
        }
        try await index.setUIDValidity(info.uidValidity, account: account.id, mailbox: mailbox)

        // Nothing arrived, left or changed flags since the last complete pass: skip the searches and fetches.
        // Gmail throttles accounts that run many commands, so an idle sync must stay this cheap.
        let snapshot = MailboxSnapshot(uidValidity: info.uidValidity, uidNext: info.uidNext,
                                       count: info.exists, modSeq: info.highestModSeq)
        if backfill == 0, refreshFlags, info.highestModSeq > 0,
           let previous = try await index.mailboxSnapshot(account: account.id, mailbox: mailbox),
           previous.uidValidity == snapshot.uidValidity, previous.uidNext == snapshot.uidNext, previous.count == snapshot.count {
            // No message arrived or left. Gmail's MODSEQ is shared by the whole account, so it moves whenever
            // anything changes anywhere; only messages whose flags changed are fetched then.
            if previous.modSeq != snapshot.modSeq {
                let known = try await index.membership(account: account.id, mailbox: mailbox)
                let gmail = await client.isGmail
                for result in try await client.uidFetchChanged(in: mailbox, since: previous.modSeq,
                                                               items: "UID FLAGS\(gmail ? " X-GM-LABELS" : "")") {
                    try await applyServerFlags(result, key: known[result.uid], mailbox: mailbox, role: role, gmail: gmail, report: &report)
                }
                try await index.setMailboxSnapshot(snapshot, account: account.id, mailbox: mailbox)
            }
            report.skippedMailboxes += 1
            return
        }

        let serverUIDs = try await client.uidSearch(in: mailbox)
        syncLog.notice("\(self.account.email, privacy: .public): \(mailbox, privacy: .public) has \(serverUIDs.count) messages")
        let known = try await index.membership(account: account.id, mailbox: mailbox)

        // Messages that left the mailbox (archived/deleted elsewhere).
        let serverSet = Set(serverUIDs)
        let removed = known.keys.filter { !serverSet.contains($0) }
        if !removed.isEmpty {
            for uid in removed {
                if let key = known[uid], let message = try await index.message(key: key) {
                    report.changedThreads.insert(message.threadID)
                }
            }
            try await index.removeMembership(account: account.id, mailbox: mailbox, uids: removed)
        }

        // Only messages inside the history limit are downloaded at all.
        var eligible = serverUIDs
        if let cutoff = policy.cutoff, !serverUIDs.isEmpty {
            let recent = Set(try await client.uidSearch(in: mailbox, "SINCE \(Self.imapDate(cutoff))"))
            eligible = serverUIDs.filter(recent.contains)
        }
        // The newest messages are synced every time; older ones come in batches through `backfill`.
        let window = Array(eligible.suffix(windowSize))
        let olderMissing = policy.downloadsHistory ? eligible.dropLast(windowSize).filter { known[$0] == nil } : []
        let history = Array(olderMissing.suffix(backfill))
        report.remainingHistory += olderMissing.count - history.count
        let newUIDs = window.filter { known[$0] == nil } + history
        let gmail = await client.isGmail
        let gmailItems = gmail ? " X-GM-THRID X-GM-LABELS" : ""

        // 1) Headers only, so messages already in the vault (e.g. both in INBOX and Sent) are not downloaded twice.
        let headers = try await client.uidFetch(in: mailbox, uids: newUIDs,
                                                items: "UID FLAGS INTERNALDATE\(gmailItems) BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]")
        var pending: [UInt32: (key: String, result: IMAPFetchResult)] = [:]
        for result in headers {
            // Drafts are handled as drafts (Koncepty), not as mail; Gmail also lists them in All Mail.
            if Self.isDraft(result) { continue }
            let header = result.body("HEADER").map { MIMEHeaders(raw: $0) }
            let messageID = header?["Message-ID"].flatMap { MIMEMessage.messageIDs(in: $0).first }
            let key = messageID.map(messageKey)
                ?? Hashing.hex("\(account.id)/\(mailbox)/\(info.uidValidity)/\(result.uid)")
            pending[result.uid] = (key, result)
        }

        // 2) Full bodies for messages we have not stored yet.
        var toDownload: [UInt32] = []
        for (uid, item) in pending where !vault.rawExists(account: account.id, key: item.key) {
            toDownload.append(uid)
        }
        var fullDownload = toDownload
        if policy.attachments == .onDemand && !toDownload.isEmpty {
            // Large messages with attachments: download text and HTML only, attachments stay on the server.
            fullDownload = []
            for chunk in toDownload.sorted().chunked(into: 50) {
                for result in try await client.uidFetch(in: mailbox, uids: chunk, items: "UID RFC822.SIZE BODYSTRUCTURE") {
                    let size = result.attributes["RFC822.SIZE"]?.text.flatMap(Int.init) ?? 0
                    guard size > Self.partialThreshold,
                          let structure = result.attributes["BODYSTRUCTURE"].flatMap(BodyStructure.parse),
                          structure.hasDeferrableParts, let item = pending[result.uid] else {
                        fullDownload.append(result.uid)
                        continue
                    }
                    let items = "UID " + structure.partialFetchItems.joined(separator: " ")
                    if let fetched = try await client.uidFetch(in: mailbox, uids: [result.uid], items: items).first,
                       let partial = structure.partialMessage(from: fetched.attributes) {
                        try vault.storeRaw(partial, account: account.id, key: item.key)
                    } else {
                        fullDownload.append(result.uid)
                    }
                }
            }
        }
        for chunk in fullDownload.sorted().chunked(into: 25) {
            for result in try await client.uidFetch(in: mailbox, uids: chunk, items: "UID BODY.PEEK[]") {
                guard let data = result.body(), let item = pending[result.uid] else { continue }
                try vault.storeRaw(data, account: account.id, key: item.key)
            }
        }

        // 3) Index the new messages and record membership.
        for (uid, item) in pending {
            let result = item.result
            let threadID = result.gmailThreadID.map { "\(account.id):gm\($0)" }
            if try await !index.hasMessage(item.key) {
                guard vault.rawExists(account: account.id, key: item.key) else { continue }
                let message = try makeStoredMessage(key: item.key, threadID: threadID, flags: result.flags,
                                                    labels: Self.tags(result, gmail: gmail, role: role),
                                                    internalDate: result.attributes["INTERNALDATE"]?.text.flatMap(MailDate.parse))
                try await index.upsert(message)
                try await indexEvent(of: message)
                report.newMessages += 1
                if role == .inbox && !message.seen { report.newInboxMessages.append(message) }
                report.changedThreads.insert(message.threadID)
            } else if pendingLocal[item.key] == nil {
                if let threadID { try await index.setThreadID(key: item.key, threadID: threadID) }
                if let message = try await index.message(key: item.key) {
                    let seen = result.flags.contains("\\Seen"), flagged = result.flags.contains("\\Flagged")
                    let labels = Self.tags(result, gmail: gmail, role: role)
                    let ownedElsewhere = gmail ? false : try await hasPreferredCopy(key: item.key, mailbox: mailbox, uid: uid, role: role)
                    if !ownedElsewhere && (seen != message.seen || flagged != message.flagged || labels != message.labels) {
                        try await index.setFlags(key: item.key, seen: seen, flagged: flagged, labels: labels)
                        report.changedThreads.insert(message.threadID)
                    }
                }
            }
            try await index.addMembership(account: account.id, mailbox: mailbox, role: role, uid: uid, key: item.key)
        }

        // 4) Refresh flags of messages we already knew (read elsewhere, starred, relabeled).
        let knownInWindow = window.filter { known[$0] != nil }
        if refreshFlags && !knownInWindow.isEmpty {
            for result in try await client.uidFetch(in: mailbox, uids: knownInWindow, items: "UID FLAGS\(gmail ? " X-GM-LABELS" : "")") {
                try await applyServerFlags(result, key: known[result.uid], mailbox: mailbox, role: role, gmail: gmail, report: &report)
            }
        }
        // Only a finished pass is remembered; after an error the next sync looks at everything again.
        if backfill == 0 && refreshFlags {
            try await index.setMailboxSnapshot(snapshot, account: account.id, mailbox: mailbox)
        }
    }

    static func isDraft(_ result: IMAPFetchResult) -> Bool {
        result.flags.contains("\\Draft") || result.gmailLabels.contains("\\Draft")
    }

    /// Takes over the flags and labels the server reports for a message we already have.
    private func applyServerFlags(_ result: IMAPFetchResult, key: String?, mailbox: String, role: MailboxRole,
                                  gmail: Bool, report: inout SyncReport) async throws {
        guard let key, pendingLocal[key] == nil, let message = try await index.message(key: key) else { return }
        // The same message in INBOX and Trash can carry different flags per copy; one copy decides.
        if !gmail, try await hasPreferredCopy(key: key, mailbox: mailbox, uid: result.uid, role: role) { return }
        let seen = result.flags.contains("\\Seen")
        let flagged = result.flags.contains("\\Flagged")
        let labels = Self.tags(result, gmail: gmail, role: role)
        if seen != message.seen || flagged != message.flagged || labels != message.labels {
            try await index.setFlags(key: key, seen: seen, flagged: flagged, labels: labels)
            report.changedThreads.insert(message.threadID)
        }
    }

    static func threadTags(_ messages: [StoredMessage]) -> [String] {
        var seen = Set<String>()
        return messages.flatMap(\.labels).filter(Tags.isUserTag).filter { seen.insert($0).inserted }
    }

    /// Re-applies Finder tags to the notes of threads carrying `tag`, e.g. after its color changed.
    public func refreshFinderTags(forTag tag: String) async throws {
        for thread in try await index.threads(filter: .tag(tag), accountID: account.id) {
            guard let filename = try await index.threadFilename(thread.id) else { continue }
            let messages = try await index.messages(inThread: thread.id)
            FinderTagPalette.shared.apply(Self.threadTags(messages), to: vault.threadURL(filename: filename))
        }
    }

    /// Gmail labels, or IMAP keywords on other servers, decoded from modified UTF-7.
    /// User and system labels of a fetched message, sorted so copies in different mailboxes compare equal.
    static func tags(_ result: IMAPFetchResult, gmail: Bool, role: MailboxRole) -> [String] {
        guard gmail else { return Tags.fromKeywords(result.flags).sorted() }
        var labels = result.gmailLabels.map(ModifiedUTF7.decode)
        // Gmail leaves the label of the selected mailbox out of X-GM-LABELS (no \\Inbox while in INBOX),
        // so without this INBOX and All Mail would flip the labels back and forth on every sync.
        if let implied = gmailLabel(for: role), !labels.contains(implied) { labels.append(implied) }
        return labels.sorted()
    }

    static func gmailLabel(for role: MailboxRole) -> String? {
        switch role {
        case .inbox: "\\Inbox"
        case .sent: "\\Sent"
        case .junk: "\\Spam"
        case .trash: "\\Trash"
        case .archive, .folder, .snoozed: nil
        }
    }

    /// Whether another copy of the message decides its flags: one in a preferred mailbox (INBOX over Archive
    /// over Trash), or an earlier one in an equally ranked mailbox. Copies can disagree, e.g. read in INBOX
    /// and unread in Trash; letting each write would flip the flags on every sync.
    private func hasPreferredCopy(key: String, mailbox: String, uid: UInt32, role: MailboxRole) async throws -> Bool {
        let mine = (Self.flagPriority(role), mailbox, uid)
        return try await index.copies(ofKey: key).contains { copy in
            let other = Self.flagPriority(copy.role)
            if other != mine.0 { return other > mine.0 }
            return (copy.mailbox, copy.uid) < (mine.1, mine.2)
        }
    }

    static func flagPriority(_ role: MailboxRole) -> Int {
        switch role {
        case .inbox: 6
        case .folder, .snoozed: 5
        case .archive: 4
        case .sent: 3
        case .junk: 2
        case .trash: 1
        }
    }

    /// Meetings in invitations go to the events table (Ranný prehľad shows today's).
    func indexEvent(of message: StoredMessage) async throws {
        guard let data = try? vault.readRaw(message.rawPath), Self.mightHaveInvite(data),
              let invite = MIMEMessage(data: data).invite else { return }
        try await index.upsertEvent(invite, message: message)
    }

    /// Cheap check before parsing: the raw message mentions a calendar part.
    static func mightHaveInvite(_ data: Data) -> Bool {
        data.range(of: Data("text/calendar".utf8)) != nil || data.range(of: Data("TEXT/CALENDAR".utf8)) != nil
            || data.range(of: Data("Text/Calendar".utf8)) != nil || data.range(of: Data(".ics".utf8)) != nil
    }

    /// One pass over the stored mail for invitations received before events were indexed.
    public func indexStoredEvents() async throws -> Int {
        var found = 0
        for message in try await index.messages(account: account.id, olderThan: Date.distantFuture) {
            guard let data = try? vault.readRaw(message.rawPath), Self.mightHaveInvite(data),
                  let invite = MIMEMessage(data: data).invite else { continue }
            try await index.upsertEvent(invite, message: message)
            found += 1
        }
        return found
    }

    func makeStoredMessage(key: String, threadID: String?, flags: [String], labels: [String],
                                   internalDate: Date? = nil) throws -> StoredMessage {
        let rawPath = vault.rawRelativePath(account: account.id, key: key)
        let mime = MIMEMessage(data: try vault.readRaw(rawPath))
        let body = mime.bestText
        let snippet = String(body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(200))
        let root = mime.references.first ?? mime.inReplyTo ?? mime.messageID ?? key
        return StoredMessage(
            key: key,
            accountID: account.id,
            messageID: mime.messageID,
            threadID: threadID ?? "\(account.id):\(Hashing.hex(root, length: 16))",
            subject: mime.subject,
            from: mime.from,
            to: mime.to,
            cc: mime.cc,
            date: mime.bestDate ?? internalDate ?? Date(),
            snippet: snippet,
            bodyText: body,
            hasHTML: mime.html != nil,
            seen: flags.contains("\\Seen"),
            flagged: flags.contains("\\Flagged"),
            labels: labels,
            rawPath: rawPath,
            inReplyTo: mime.inReplyTo,
            references: mime.references,
            attachments: mime.attachments.map(\.filename)
        )
    }

    // MARK: - Thread notes

    /// Regenerates `threads/*.md` for the given threads and returns the file names.
    @discardableResult
    public func writeThreadFiles(_ threadIDs: Set<String>) async throws -> [String: String] {
        var result: [String: String] = [:]
        for threadID in threadIDs {
            let messages = try await index.messages(inThread: threadID)
            guard let first = messages.first else { continue }
            let filename = try await filename(for: threadID, subject: messages.last?.subject ?? first.subject, date: first.date)
            let markdown = ThreadMarkdown.render(messages: messages, ownAddresses: [account.email])
            try vault.writeThread(markdown, filename: filename)
            // The note carries the thread's tags as Finder tags, so Finder and Spotlight find it by tag.
            FinderTagPalette.shared.apply(Self.threadTags(messages), to: vault.threadURL(filename: filename))
            result[threadID] = filename
        }
        return result
    }

    public func threadMarkdown(_ threadID: String) async throws -> (markdown: String, filename: String)? {
        let messages = try await index.messages(inThread: threadID)
        guard let first = messages.first else { return nil }
        let filename = try await filename(for: threadID, subject: messages.last?.subject ?? first.subject, date: first.date)
        return (ThreadMarkdown.render(messages: messages, ownAddresses: [account.email]), filename)
    }

    /// The thread with its attachment files, ready for `ObsidianExporter.export(thread:)`.
    public func exportedThread(_ threadID: String) async throws -> ExportedThread? {
        // Attachments are part of the export, so complete messages that were stored without them.
        for message in try await index.messages(inThread: threadID) where !message.attachments.isEmpty {
            try await materialize(key: message.key)
        }
        let messages = try await index.messages(inThread: threadID)
        guard let first = messages.first else { return nil }
        let filename = try await filename(for: threadID, subject: messages.last?.subject ?? first.subject, date: first.date)
        var files: [ExportedThread.File] = []
        for message in messages where !message.attachments.isEmpty {
            guard let data = try? vault.readRaw(message.rawPath) else { continue }
            for part in MIMEMessage(data: data).root.leaves where part.isAttachment {
                files.append(.init(messageKey: message.key, filename: part.filename ?? "príloha",
                                   mimeType: part.mimeType, data: part.decodedBody))
            }
        }
        return ExportedThread(filename: filename, messages: messages, ownAddresses: [account.email], attachments: files)
    }

    private func filename(for threadID: String, subject: String, date: Date) async throws -> String {
        if let existing = try await index.threadFilename(threadID) { return existing }
        var filename = ThreadMarkdown.filename(subject: subject, date: date)
        if try await index.isFilenameTaken(filename, byOtherThan: threadID) {
            filename = ThreadMarkdown.filename(subject: subject, date: date, suffix: String(Hashing.hex(threadID).prefix(6)))
        }
        try await index.setThreadFilename(threadID, filename)
        return filename
    }

    // MARK: - Actions

    public func markThreadSeen(_ threadID: String) async throws {
        let unread = try await index.uids(inThread: threadID, role: .inbox).filter { !$0.seen }
        guard !unread.isEmpty else { return }
        try await index.setSeen(keys: unread.map(\.key))
        try await withClient { client in
            for (mailbox, items) in Dictionary(grouping: unread, by: \.mailbox) {
                try await client.uidStore(in: mailbox, uids: items.map(\.uid), "+FLAGS.SILENT (\\Seen)")
            }
        }
    }

    /// Stars or unstars every message of the thread (IMAP \\Flagged, the Gmail star).
    public func setStarred(_ threadID: String, _ starred: Bool) async throws {
        let messages = try await index.messages(inThread: threadID)
        let keys = messages.map(\.key)
        // Local first, so every view shows the change at once; the server follows.
        try await index.setFlagged(keys: keys, starred)
        try await withLocalChange(keys) {
            try await setFlag("\\Flagged", starred, threadID: threadID)
        } revert: {
            for message in messages { try? await index.setFlagged(keys: [message.key], message.flagged) }
        }
    }

    /// Marks every message of the thread read or unread.
    public func setSeen(_ threadID: String, _ seen: Bool) async throws {
        let messages = try await index.messages(inThread: threadID)
        let keys = messages.map(\.key)
        try await index.setSeen(keys: keys, seen)
        try await withLocalChange(keys) {
            try await setFlag("\\Seen", seen, threadID: threadID)
        } revert: {
            for message in messages { try? await index.setSeen(keys: [message.key], message.seen) }
        }
    }

    /// Keys with a local change the server has not confirmed yet; sync must not overwrite them.
    private var pendingLocal: [String: Int] = [:]

    private func withLocalChange(_ keys: [String], _ operation: () async throws -> Void,
                                 revert: () async -> Void) async throws {
        for key in keys { pendingLocal[key, default: 0] += 1 }
        defer {
            for key in keys {
                pendingLocal[key, default: 1] -= 1
                if pendingLocal[key] == 0 { pendingLocal[key] = nil }
            }
        }
        do {
            try await operation()
        } catch {
            await revert()
            throw error
        }
    }

    private func setFlag(_ flag: String, _ on: Bool, threadID: String) async throws {
        let copies = try await index.copies(inThread: threadID)
        guard !copies.isEmpty else { return }
        try await withClient { client in
            for (mailbox, items) in Dictionary(grouping: copies, by: \.mailbox) {
                try await client.uidStore(in: mailbox, uids: items.map(\.uid), "\(on ? "+" : "-")FLAGS.SILENT (\(flag))")
            }
        }
    }

    /// Adds or removes a tag on every message of the thread: a Gmail label, or an IMAP keyword elsewhere.
    /// Tags compare case-insensitively, so removing "práca" also removes "Práca".
    public func setTag(_ tag: String, _ on: Bool, threadID: String) async throws {
        let key = Tags.fold(tag)
        let messages = try await index.messages(inThread: threadID)
        // Spellings of this tag already on the messages (on the server they are separate labels/keywords).
        let variants = Set(messages.flatMap(\.labels).filter { Tags.fold($0) == key })
        for message in messages {
            var labels = message.labels.filter { Tags.fold($0) != key }
            if on { labels.append(message.labels.first { Tags.fold($0) == key } ?? tag) }
            try await index.setLabels(key: message.key, labels)
        }
        let copies = try await index.copies(inThread: threadID)
        // Adding: nothing to do when every message has the tag in some spelling. Removing: every spelling.
        let names = on ? (messages.allSatisfy { $0.labels.contains { Tags.fold($0) == key } } ? [] : [tag])
                       : Array(variants.union([tag]))
        if !copies.isEmpty && !names.isEmpty {
            try await withLocalChange(messages.map(\.key)) {
                try await withClient { client in
                    let gmail = await client.isGmail
                    for name in names {
                        let change: String
                        if gmail {
                            change = "\(on ? "+" : "-")X-GM-LABELS (\(IMAPClient.quoted(ModifiedUTF7.encode(name))))"
                        } else {
                            change = "\(on ? "+" : "-")FLAGS.SILENT (\(ModifiedUTF7.keyword(forTag: name)))"
                        }
                        for (mailbox, items) in Dictionary(grouping: copies, by: \.mailbox) {
                            try await client.uidStore(in: mailbox, uids: items.map(\.uid), change)
                        }
                    }
                }
            } revert: {
                for message in messages { try? await index.setLabels(key: message.key, message.labels) }
            }
        }
        try await writeThreadFiles([threadID])
    }

    /// Moves the thread from the inbox (or the Trash, or a folder) to the archive.
    public func archiveThread(_ threadID: String) async throws {
        let inInbox = try await index.uids(inThread: threadID, role: .inbox) + index.uids(inThread: threadID, role: .trash)
            + index.uids(inThread: threadID, role: .folder) + index.uids(inThread: threadID, role: .junk)
        guard !inInbox.isEmpty else { return }
        for (mailbox, items) in Dictionary(grouping: inInbox, by: \.mailbox) {
            try await index.removeMembership(account: account.id, mailbox: mailbox, uids: items.map(\.uid))
        }
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let gmail = await client.isGmail
            let archive: IMAPMailbox
            if gmail {
                guard let all = self.mailbox(withAttribute: "\\all") else { throw IMAPError.missingMailbox("Všetka pošta") }
                archive = all
            } else {
                archive = try await self.archiveMailbox(client: client)
            }
            for (mailbox, items) in Dictionary(grouping: inInbox, by: \.mailbox) {
                try await client.uidMove(in: mailbox, uids: items.map(\.uid), to: archive.name)
            }
        }
        _ = try await sync()
        try await writeThreadFiles([threadID])
    }

    /// Moves the thread to the Trash. With `permanently`, removes it from the server and the vault for good.
    public func deleteThread(_ threadID: String, permanently: Bool = false) async throws {
        let copies = try await index.allUIDs(inThread: threadID)
        if permanently {
            if !copies.isEmpty {
                try await withClient { client in
                    for (mailbox, items) in Dictionary(grouping: copies, by: \.mailbox) {
                        try await client.uidExpunge(in: mailbox, uids: items.map(\.uid))
                    }
                }
            }
            let removed = try await index.deleteThread(threadID)
            for path in removed.rawPaths {
                try? FileManager.default.removeItem(at: vault.root.appending(path: path))
            }
            if let filename = removed.filename {
                try? FileManager.default.removeItem(at: vault.threadURL(filename: filename))
            }
            return
        }
        var toMove = copies.filter { $0.role != .trash }
        guard !toMove.isEmpty else { return }
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let trash = try await self.ensureMailbox(attribute: "\\trash", names: Self.trashNames, create: "Trash", client: client)
            // Gmail: a message is one object with labels. Moving its All Mail copy to Trash removes it from
            // Inbox and Sent too; moving those copies afterwards would ask for messages that are gone
            // ("NO System Error"). So only the All Mail (or, if not there, Spam) copies are moved.
            if await client.isGmail {
                let allMail = toMove.filter { $0.role == .archive }
                let rest = toMove.filter { $0.role == .junk }
                toMove = allMail.isEmpty ? (rest.isEmpty ? toMove : rest) : allMail
            }
            var lastError: Error?
            for (mailbox, items) in Dictionary(grouping: toMove, by: \.mailbox) where mailbox != trash.name {
                do {
                    try await client.uidMove(in: mailbox, uids: items.map(\.uid), to: trash.name)
                    try await self.index.removeMembership(account: self.account.id, mailbox: mailbox, uids: items.map(\.uid))
                } catch {
                    // One folder failing must not leave the others behind; report it after trying all.
                    syncLog.error("\(self.account.email, privacy: .public): move to trash from \(mailbox, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    lastError = error
                }
            }
            if let lastError { throw lastError }
        }
        // The Trash copies get their membership on the next sync.
        _ = try await sync()
    }

    /// Moves a thread from Archive or Trash back to the inbox.
    public func moveThreadToInbox(_ threadID: String) async throws {
        try await index.removeSnooze(threadID: threadID)
        let copies = try await index.allUIDs(inThread: threadID).filter {
            $0.role == .archive || $0.role == .trash || $0.role == .folder || $0.role == .junk || $0.role == .snoozed
        }
        guard !copies.isEmpty else { return }
        try await withClient { client in
            let gmail = await client.isGmail
            for (mailbox, items) in Dictionary(grouping: copies, by: \.mailbox) {
                let uids = items.map(\.uid)
                if gmail && items.first?.role == .archive {
                    // In Gmail, All Mail always keeps the message; copying to INBOX adds the Inbox label.
                    try await client.uidCopy(in: mailbox, uids: uids, to: "INBOX")
                } else {
                    try await client.uidMove(in: mailbox, uids: uids, to: "INBOX")
                    try await self.index.removeMembership(account: self.account.id, mailbox: mailbox, uids: uids)
                }
            }
        }
        _ = try await sync()
    }

    private static let snoozedNames = ["Odložené", "Snoozed"]

    private var snoozedMailbox: IMAPMailbox? {
        mailbox(attribute: "\\none", names: Self.snoozedNames)
    }

    /// Takes the thread out of the inbox until `until`: it moves to the "Odložené" folder (a label on Gmail),
    /// and `wakeSnoozed` brings it back.
    public func snoozeThread(_ threadID: String, until: Date) async throws {
        try await index.setSnooze(threadID: threadID, account: account.id, until: until)
        let inInbox = try await index.uids(inThread: threadID, role: .inbox)
        guard !inInbox.isEmpty else { return }
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let folder = try await self.ensureMailbox(attribute: "\\none", names: Self.snoozedNames,
                                                      create: ModifiedUTF7.encode("Odložené"), client: client)
            for (mailbox, items) in Dictionary(grouping: inInbox, by: \.mailbox) {
                try await client.uidMove(in: mailbox, uids: items.map(\.uid), to: folder.name)
                try await self.index.removeMembership(account: self.account.id, mailbox: mailbox, uids: items.map(\.uid))
            }
        }
        _ = try await sync()
    }

    /// Brings a snoozed thread back to the inbox, marked unread so it stands out.
    public func wakeSnoozed(_ threadID: String) async throws {
        try await moveThreadToInbox(threadID)
        try await setSeen(threadID, false)
    }

    private static let archiveNames = ["Archive", "Archív", "Archiv"]
    private static let trashNames = ["Trash", "Deleted Items", "Deleted Messages", "Kôš", "Koš", "Bin"]

    /// Sends the draft and stores the sent message in the vault right away.
    public func send(_ draft: Draft) async throws -> SendResult {
        let (data, messageID) = MessageBuilder.build(draft)
        let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort, username: account.username, password: password,
                              security: account.smtpSecurity)
        try await smtp.send(data, from: account.email, to: draft.recipients.map(\.address))

        let key = messageKey(messageID)
        try vault.storeRaw(data, account: account.id, key: key)
        var threadID: String?
        if let parent = draft.inReplyTo { threadID = try await index.threadID(forMessageID: parent) }
        let message = try makeStoredMessage(key: key, threadID: threadID, flags: ["\\Seen"], labels: [])
        try await index.upsert(message)
        // Count it as sent right away (reply icon, Sent view); the next sync of Sent swaps in the real UID.
        if let sent = sentMailbox {
            try await index.addMembership(account: account.id, mailbox: sent.name, role: .sent,
                                          uid: UInt32.max - UInt32.random(in: 0..<1_000_000), key: key)
        }
        try await writeThreadFiles([message.threadID])
        return SendResult(threadID: message.threadID, raw: data)
    }

    /// Gmail stores sent mail by itself; other servers need an explicit copy in Sent.
    /// Waits for the account's connection (a sync may hold it), so callers run it in the background.
    public func copyToSent(_ data: Data) async throws {
        let gmail = try await withClient { await $0.isGmail }
        guard !gmail else { return }
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let sent = try await self.ensureMailbox(attribute: "\\sent", names: Self.sentNames, create: "Sent", client: client)
            try await client.append(to: sent.name, flags: ["\\Seen"], message: data)
        }
    }

    public func disconnect() async {
        await client.disconnect()
    }

    /// Messages up to this size are always downloaded whole; skipping attachments is not worth it.
    static let partialThreshold = 100_000

    /// Downloads the complete message when only its text was stored (attachments on demand).
    public func materialize(key: String) async throws {
        guard let message = try await index.message(key: key),
              let data = try? vault.readRaw(message.rawPath), MIMEMessage(data: data).isPartial else { return }
        guard let location = try await index.location(ofKey: key) else {
            throw IMAPError.missingMailbox("Správa už nie je na serveri")
        }
        let full = try await withClient { client in
            try await client.uidFetch(in: location.mailbox, uids: [location.uid], items: "UID BODY.PEEK[]").first?.body()
        }
        guard let full else { throw IMAPError.missingMailbox("Správu sa nepodarilo stiahnuť") }
        try vault.storeRaw(full, account: account.id, key: key)
    }

    /// Drops attachment contents from stored messages (they stay on the server); returns messages and bytes freed.
    public func stripAttachments() async throws -> (messages: Int, bytes: Int) {
        var count = 0, freed = 0
        for message in try await index.messagesWithAttachments(account: account.id) {
            // Only messages still on the server can be completed again later.
            guard try await index.location(ofKey: message.key) != nil,
                  let data = try? vault.readRaw(message.rawPath),
                  let stripped = AttachmentStripper.strip(data) else { continue }
            try vault.storeRaw(stripped, account: account.id, key: message.key)
            count += 1
            freed += data.count - stripped.count
        }
        return (count, freed)
    }

    /// IMAP search date, e.g. `14-Oct-2023`.
    static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    /// Removes local messages older than the history limit (they stay on the server).
    /// Returns how many messages were removed.
    @discardableResult
    public func pruneHistory() async throws -> Int {
        guard let cutoff = policy.cutoff else { return 0 }
        let old = try await index.messages(account: account.id, olderThan: cutoff)
        var rewrite = Set<String>()
        for (threadID, items) in Dictionary(grouping: old, by: \.threadID) {
            let all = try await index.messages(inThread: threadID)
            if all.count == items.count {
                let removed = try await index.deleteThread(threadID)
                for path in removed.rawPaths { try? FileManager.default.removeItem(at: vault.root.appending(path: path)) }
                if let filename = removed.filename { try? FileManager.default.removeItem(at: vault.threadURL(filename: filename)) }
            } else {
                for message in items {
                    try await index.deleteMessage(key: message.key)
                    try? FileManager.default.removeItem(at: vault.root.appending(path: message.rawPath))
                }
                rewrite.insert(threadID)
            }
        }
        try await writeThreadFiles(rewrite)
        return old.count
    }

    // MARK: - Helpers

    /// Index key of a message. It includes the account, so the same email in two accounts
    /// (e.g. sent from one of your addresses to another) is stored once per account.
    func messageKey(_ messageID: String) -> String {
        Hashing.hex("\(account.id)/\(messageID)")
    }

    private func mailbox(withAttribute attribute: String) -> IMAPMailbox? {
        mailboxes.first { $0.has(attribute) }
    }

    /// Prefers the SPECIAL-USE attribute; many servers (e.g. older Dovecot setups) only have well-known names.
    private func mailbox(attribute: String, names: [String]) -> IMAPMailbox? {
        if let match = mailbox(withAttribute: attribute) { return match }
        for name in names {
            if let match = mailboxes.first(where: { $0.leafName.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        }
        return nil
    }

    private var sentMailbox: IMAPMailbox? {
        mailbox(attribute: "\\sent", names: Self.sentNames)
    }

    private static let draftNames = ["Drafts", "Koncepty", "Concepts", "Rozpísané správy", "Draft"]

    // MARK: Drafts on the server

    /// Puts the newest version of a draft into the Drafts folder and removes older versions (same Message-ID).
    public func uploadDraft(_ data: Data, messageID: String) async throws {
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            let drafts = try await self.ensureMailbox(attribute: "\\drafts", names: Self.draftNames, create: "Drafts", client: client)
            try await client.append(to: drafts.name, flags: ["\\Draft", "\\Seen"], message: data)
            let copies = try await client.uidSearch(in: drafts.name, "HEADER Message-ID \(IMAPClient.quoted("<\(messageID)>"))")
            if copies.count > 1 {
                try await client.uidExpunge(in: drafts.name, uids: Array(copies.sorted().dropLast()))
            }
        }
    }

    /// Removes a draft from the Drafts folder (it was sent or discarded).
    public func deleteServerDraft(messageID: String) async throws {
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            guard let drafts = self.mailbox(attribute: "\\drafts", names: Self.draftNames) else { return }
            let copies = try await client.uidSearch(in: drafts.name, "HEADER Message-ID \(IMAPClient.quoted("<\(messageID)>"))")
            try await client.uidExpunge(in: drafts.name, uids: copies)
        }
    }

    /// Message-IDs of every draft on the server, and the full messages of those not in `known`.
    /// Nil when the account has no Drafts folder yet (then nothing can have been removed from it).
    public func serverDrafts(known: Set<String>) async throws -> (present: Set<String>, new: [Data])? {
        try await withClient { client in
            if self.mailboxes.isEmpty { self.mailboxes = try await client.listMailboxes() }
            guard let drafts = self.mailbox(attribute: "\\drafts", names: Self.draftNames) else { return nil }
            let uids = try await client.uidSearch(in: drafts.name)
            var present: Set<String> = []
            var missing: [UInt32] = []
            for result in try await client.uidFetch(in: drafts.name, uids: uids, items: "UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]") {
                guard let header = result.body("HEADER").map({ MIMEHeaders(raw: $0) }),
                      let id = header["Message-ID"].flatMap({ MIMEMessage.messageIDs(in: $0).first }) else { continue }
                present.insert(id)
                if !known.contains(id) { missing.append(result.uid) }
            }
            var new: [Data] = []
            for result in try await client.uidFetch(in: drafts.name, uids: missing, items: "UID BODY.PEEK[]") {
                if let data = result.body() { new.append(data) }
            }
            return (present, new)
        }
    }

    private static let sentNames = ["Sent", "Sent Items", "Sent Messages", "Sent Mail", "Odoslané", "Odoslaná pošta", "Odeslané"]

    private func archiveMailbox(client: IMAPClient) async throws -> IMAPMailbox {
        try await ensureMailbox(attribute: "\\archive", names: Self.archiveNames, create: "Archive", client: client)
    }

    /// Finds a special folder, creating it next to INBOX's children when the server has none.
    private func ensureMailbox(attribute: String, names: [String], create leaf: String, client: IMAPClient) async throws -> IMAPMailbox {
        if let existing = mailbox(attribute: attribute, names: names) { return existing }
        var delimiter = mailboxes.first { $0.delimiter != nil }?.delimiter ?? "/"
        // Servers with an "INBOX." namespace keep every folder under INBOX; ask the server, fall back to a guess.
        var prefix = mailboxes.contains { $0.name.uppercased().hasPrefix("INBOX\(delimiter)") } ? "INBOX\(delimiter)" : ""
        if let namespace = try await client.personalNamespace() {
            prefix = namespace.prefix
            if !namespace.delimiter.isEmpty { delimiter = namespace.delimiter }
        }
        let name = prefix + leaf
        try await client.create(name)
        mailboxes = try await client.listMailboxes()
        return mailboxes.first { $0.name == name } ?? IMAPMailbox(name: name, attributes: [], delimiter: delimiter)
    }

    /// One server operation at a time per account. The actor alone is not enough: it is reentrant,
    /// so while one operation waits for the network another could send commands on the same
    /// connection and read its responses (this desynchronized Gmail sync and history download).
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            // Hand the lock straight to the next waiter.
            waiting.removeFirst().resume()
        }
    }

    /// Runs an operation on a connected client, reconnecting once if the connection dropped.
    /// Operations must not call `withClient` (or `sync`) from inside `operation`.
    private func withClient<T>(_ operation: (IMAPClient) async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        if await !client.isConnected {
            syncLog.notice("\(self.account.email, privacy: .public): connecting")
            try await client.connect()
            syncLog.notice("\(self.account.email, privacy: .public): connected")
        }
        do {
            return try await operation(client)
        } catch is ConnectionError {
            await client.disconnect()
            client = IMAPClient(host: account.imapHost, port: account.imapPort, username: account.username, password: password,
                                security: account.imapSecurity)
            try await client.connect()
            return try await operation(client)
        }
    }
}
