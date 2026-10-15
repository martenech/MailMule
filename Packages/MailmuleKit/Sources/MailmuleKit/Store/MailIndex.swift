import Foundation

/// The SQLite index inside `.mailmule/`. It is a cache: messages live as `.eml` files in the vault,
/// and server state (flags, mailbox membership) is re-fetched on sync.
/// The state of a mailbox as reported by SELECT. Equal snapshots mean nothing arrived, left or changed flags.
public struct MailboxSnapshot: Equatable, Sendable {
    public var uidValidity: UInt32
    public var uidNext: UInt32
    public var count: UInt32
    /// CONDSTORE HIGHESTMODSEQ; changes with every flag change. 0 when the server has no CONDSTORE.
    public var modSeq: UInt64

    public init(uidValidity: UInt32, uidNext: UInt32, count: UInt32, modSeq: UInt64) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.count = count
        self.modSeq = modSeq
    }
}

public actor MailIndex {
    private let db: SQLiteDatabase

    /// Bump when stored keys or schema change incompatibly; the cache is then rebuilt from the server.
    /// 3: rebuild after concurrent commands on one connection could mix up messages between folders.
    /// 4: dates re-read from stored messages (lenient parser), no rebuild.
    static let schemaVersion = 4

    /// True when an older index was discarded on open; raw files keyed the old way should be removed too.
    public nonisolated let wasReset: Bool
    /// The index predates the lenient date parser; call `repairDates(vault:)` once.
    public nonisolated let needsDateRepair: Bool

    public init(url: URL) throws {
        let db = try SQLiteDatabase(url: url)
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        let hasData = try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages'").isEmpty
        var reset = false
        needsDateRepair = hasData && version == 3
        if version < 3 && hasData {
            for table in ["messages", "membership", "mailbox_state", "thread_files", "messages_fts"] {
                try db.execute("DROP TABLE IF EXISTS \(table)")
            }
            reset = true
        }
        try Self.migrate(db)
        try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        self.db = db
        wasReset = reset
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            key TEXT PRIMARY KEY,
            account TEXT NOT NULL,
            message_id TEXT,
            thread_id TEXT NOT NULL,
            subject TEXT NOT NULL,
            from_name TEXT,
            from_addr TEXT,
            to_json TEXT NOT NULL,
            cc_json TEXT NOT NULL,
            date REAL NOT NULL,
            snippet TEXT NOT NULL,
            body_text TEXT NOT NULL,
            has_html INTEGER NOT NULL,
            seen INTEGER NOT NULL,
            flagged INTEGER NOT NULL,
            labels_json TEXT NOT NULL,
            raw_path TEXT NOT NULL,
            in_reply_to TEXT,
            references_json TEXT NOT NULL,
            attachments_json TEXT NOT NULL
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS messages_date ON messages(date)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS membership (
            account TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            role TEXT,
            uid INTEGER NOT NULL,
            key TEXT NOT NULL,
            PRIMARY KEY (account, mailbox, uid)
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS membership_key ON membership(key)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS mailbox_snapshot (
            account TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid_validity INTEGER NOT NULL,
            uid_next INTEGER NOT NULL,
            message_count INTEGER NOT NULL,
            modseq INTEGER NOT NULL,
            PRIMARY KEY (account, mailbox)
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS mailbox_state (
            account TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid_validity INTEGER NOT NULL,
            PRIMARY KEY (account, mailbox)
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS thread_files (
            thread_id TEXT PRIMARY KEY,
            filename TEXT NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS events (
            uid TEXT PRIMARY KEY,
            message_key TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            account TEXT NOT NULL,
            summary TEXT NOT NULL,
            start REAL,
            end_date REAL,
            all_day INTEGER NOT NULL,
            location TEXT,
            method TEXT NOT NULL,
            cancelled INTEGER NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS thread_summaries (
            thread_id TEXT PRIMARY KEY,
            summary TEXT NOT NULL,
            latest_key TEXT NOT NULL,
            created REAL NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS follow_ups (
            thread_id TEXT PRIMARY KEY,
            account TEXT NOT NULL,
            due REAL NOT NULL,
            since REAL NOT NULL,
            fired INTEGER NOT NULL DEFAULT 0
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS snoozes (
            thread_id TEXT PRIMARY KEY,
            account TEXT NOT NULL,
            wake_at REAL NOT NULL
        )
        """)
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            key UNINDEXED, subject, people, body, tokenize = 'unicode61 remove_diacritics 2'
        )
        """)
    }

    /// Re-reads each message's date from its stored header block and fixes wrong ones.
    /// Returns how many dates changed.
    @discardableResult
    public func repairDates(vault: MailVault) throws -> Int {
        var changed = 0
        for row in try db.query("SELECT key, raw_path, date FROM messages") {
            guard let key = row.string("key"), let path = row.string("raw_path"),
                  let handle = try? FileHandle(forReadingFrom: vault.root.appending(path: path)) else { continue }
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            guard let date = MIMEMessage.bestDate(headerData: head) else { continue }
            if abs(date.timeIntervalSince1970 - row.double("date")) > 60 {
                try db.execute("UPDATE messages SET date = ? WHERE key = ?", [date.timeIntervalSince1970, key])
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Messages

    public func hasMessage(_ key: String) throws -> Bool {
        try !db.query("SELECT 1 FROM messages WHERE key = ?", [key]).isEmpty
    }

    public func upsert(_ m: StoredMessage) throws {
        try db.transaction {
            try db.execute("""
            INSERT OR REPLACE INTO messages (key, account, message_id, thread_id, subject, from_name, from_addr,
                to_json, cc_json, date, snippet, body_text, has_html, seen, flagged, labels_json, raw_path,
                in_reply_to, references_json, attachments_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                m.key, m.accountID, m.messageID, m.threadID, m.subject, m.from?.name, m.from?.address,
                Self.json(m.to), Self.json(m.cc), m.date.timeIntervalSince1970, m.snippet, m.bodyText,
                m.hasHTML, m.seen, m.flagged, Self.json(m.labels), m.rawPath,
                m.inReplyTo, Self.json(m.references), Self.json(m.attachments),
            ])
            try db.execute("DELETE FROM messages_fts WHERE key = ?", [m.key])
            let people = ([m.from].compactMap { $0 } + m.to + m.cc)
                .map { "\($0.name ?? "") \($0.address)" }.joined(separator: " ")
            try db.execute("INSERT INTO messages_fts (key, subject, people, body) VALUES (?, ?, ?, ?)",
                           [m.key, m.subject, people, m.bodyText])
        }
    }

    public func setFlags(key: String, seen: Bool, flagged: Bool, labels: [String]?) throws {
        if let labels {
            try db.execute("UPDATE messages SET seen = ?, flagged = ?, labels_json = ? WHERE key = ?",
                           [seen, flagged, Self.json(labels), key])
        } else {
            try db.execute("UPDATE messages SET seen = ?, flagged = ? WHERE key = ?", [seen, flagged, key])
        }
    }

    public func setSeen(keys: [String]) throws {
        for key in keys {
            try db.execute("UPDATE messages SET seen = 1 WHERE key = ?", [key])
        }
    }

    public func setThreadID(key: String, threadID: String) throws {
        try db.execute("UPDATE messages SET thread_id = ? WHERE key = ?", [threadID, key])
    }

    public func messages(inThread threadID: String) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE thread_id = ? ORDER BY date ASC", [threadID]).map(Self.message)
    }

    public func messages(account: String, olderThan date: Date) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE account = ? AND date < ?", [account, date.timeIntervalSince1970]).map(Self.message)
    }

    /// Messages with attachments, newest first, outside Trash and Spam (for the Prílohy view).
    public func attachmentMessages(accountID: String?, limit: Int = 3000) throws -> [StoredMessage] {
        try db.query("""
        SELECT * FROM messages WHERE attachments_json != '[]' AND (? IS NULL OR account = ?)
          AND key NOT IN (SELECT key FROM membership WHERE role IN ('trash', 'junk'))
        ORDER BY date DESC LIMIT ?
        """, [accountID, accountID, limit]).map(Self.message)
    }

    public func messagesWithAttachments(account: String) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE account = ? AND attachments_json != '[]'", [account]).map(Self.message)
    }

    /// A server copy of the message (any folder), for fetching it again.
    public func location(ofKey key: String) throws -> (mailbox: String, uid: UInt32)? {
        try db.query("SELECT mailbox, uid FROM membership WHERE key = ? LIMIT 1", [key]).first.map {
            ($0.string("mailbox") ?? "", UInt32($0.int("uid")))
        }
    }

    /// Removes everything stored for an account; returns the note filenames of its threads.
    public func removeAccount(_ account: String) throws -> [String] {
        let filenames = try db.query("""
        SELECT DISTINCT f.filename FROM thread_files f JOIN messages m ON m.thread_id = f.thread_id WHERE m.account = ?
        """, [account]).compactMap { $0.string("filename") }
        try db.transaction {
            try db.execute("DELETE FROM thread_files WHERE thread_id IN (SELECT thread_id FROM messages WHERE account = ?)", [account])
            try db.execute("DELETE FROM messages_fts WHERE key IN (SELECT key FROM messages WHERE account = ?)", [account])
            try db.execute("DELETE FROM messages WHERE account = ?", [account])
            try db.execute("DELETE FROM membership WHERE account = ?", [account])
            try db.execute("DELETE FROM mailbox_state WHERE account = ?", [account])
            try db.execute("DELETE FROM mailbox_snapshot WHERE account = ?", [account])
        }
        return filenames
    }

    /// Removes drafts that earlier versions indexed as mail (Gmail keeps drafts in All Mail); returns their raw paths.
    public func removeDraftMessages() throws -> [String] {
        let rows = try db.query("SELECT key, raw_path FROM messages WHERE labels_json LIKE '%\"\\\\Draft\"%'")
        for row in rows {
            if let key = row.string("key") { try deleteMessage(key: key) }
        }
        return rows.compactMap { $0.string("raw_path") }
    }

    public func deleteMessage(key: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM membership WHERE key = ?", [key])
            try db.execute("DELETE FROM messages_fts WHERE key = ?", [key])
            try db.execute("DELETE FROM messages WHERE key = ?", [key])
        }
    }

    public func message(key: String) throws -> StoredMessage? {
        try db.query("SELECT * FROM messages WHERE key = ?", [key]).first.map(Self.message)
    }

    /// Finds the thread of a message we replied to, so a sent reply lands in the same thread.
    public func threadID(forMessageID messageID: String) throws -> String? {
        try db.query("SELECT thread_id FROM messages WHERE message_id = ? LIMIT 1", [messageID]).first?.string("thread_id")
    }

    // MARK: - Threads

    /// Threads in a mailbox view; `accountID` nil means all accounts (unified view).
    public func threads(filter: ThreadFilter, accountID: String? = nil, search: String? = nil,
                        options: ThreadListOptions = .init(), limit: Int = 1000) throws -> [ThreadSummary] {
        var conditions: [String] = []
        var params: [SQLBindable] = []
        if let accountID {
            conditions.append("account = ?")
            params.append(accountID)
        }
        let inRole = { (role: String) in
            "thread_id IN (SELECT m.thread_id FROM messages m JOIN membership b ON b.key = m.key WHERE b.role = '\(role)')"
        }
        switch filter {
        case .inbox:
            conditions.append(inRole("inbox"))
            conditions.append("thread_id NOT IN (SELECT thread_id FROM snoozes)")
        case .sent:
            conditions.append(inRole("sent"))
            conditions.append("NOT " + inRole("trash"))
        case .archive:
            // Gmail's archive is All Mail, which also holds inbox threads.
            conditions += [inRole("archive"), "NOT " + inRole("inbox"), "NOT " + inRole("trash")]
        case .trash:
            conditions.append(inRole("trash"))
        case .all:
            conditions.append("NOT " + inRole("trash"))
            conditions.append("NOT " + inRole("junk"))
        case .junk:
            conditions.append(inRole("junk"))
        case .snoozed:
            // Snoozed locally (the server move may still be pending) or sitting in the Snoozed folder.
            conditions.append("(thread_id IN (SELECT thread_id FROM snoozes) OR " + inRole("snoozed") + ")")
        case .followUps:
            conditions.append("thread_id IN (SELECT thread_id FROM follow_ups)")
        case .starred:
            conditions.append("thread_id IN (SELECT thread_id FROM messages WHERE flagged = 1)")
            conditions.append("NOT " + inRole("trash"))
        case .folder(let mailbox):
            conditions.append("thread_id IN (SELECT m.thread_id FROM messages m JOIN membership b ON b.key = m.key WHERE b.mailbox = ?)")
            params.append(mailbox)
        case .tag(let tag):
            conditions.append("thread_id IN (SELECT m.thread_id FROM messages m, json_each(m.labels_json) j WHERE mm_fold(j.value) = mm_fold(?))")
            params.append(tag)
            conditions.append("NOT " + inRole("trash"))
        }
        if let search {
            let query = SearchQuery(search)
            if let match = Self.ftsQuery(query.text.joined(separator: " ")) {
                conditions.append("thread_id IN (SELECT m.thread_id FROM messages m JOIN messages_fts f ON f.key = m.key WHERE messages_fts MATCH ?)")
                params.append(match)
            }
            // Operators apply to one message of the thread (like Gmail): from:jan after:2026-09 finds Ján's mail since September.
            var message: [String] = []
            for value in query.from {
                message.append("(mm_search(COALESCE(from_addr, '')) LIKE mm_search(?) OR mm_search(COALESCE(from_name, '')) LIKE mm_search(?))")
                params += ["%\(value)%", "%\(value)%"]
            }
            for value in query.to {
                message.append("(mm_search(to_json) LIKE mm_search(?) OR mm_search(cc_json) LIKE mm_search(?))")
                params += ["%\(value)%", "%\(value)%"]
            }
            for value in query.with {
                message.append("(mm_search(COALESCE(from_addr, '')) LIKE mm_search(?) OR mm_search(to_json) LIKE mm_search(?) OR mm_search(cc_json) LIKE mm_search(?))")
                params += ["%\(value)%", "%\(value)%", "%\(value)%"]
            }
            for value in query.subject {
                message.append("mm_search(subject) LIKE mm_search(?)")
                params.append("%\(value)%")
            }
            if query.hasAttachment { message.append("attachments_json != '[]'") }
            if let unread = query.unread { message.append(unread ? "seen = 0" : "seen = 1") }
            if query.starred { message.append("flagged = 1") }
            if let after = query.after {
                message.append("date >= ?")
                params.append(after.timeIntervalSince1970)
            }
            if let before = query.before {
                message.append("date < ?")
                params.append(before.timeIntervalSince1970)
            }
            if !message.isEmpty {
                conditions.append("thread_id IN (SELECT thread_id FROM messages WHERE \(message.joined(separator: " AND ")))")
            }
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        // In a mailbox view the row shows the newest message that is in that mailbox, so your own reply
        // (it lives in Sent) does not replace the received mail in the Inbox or move the thread to the top.
        var viewMembership: String?
        var viewParams: [SQLBindable] = []
        switch filter {
        case .inbox: viewMembership = "role = 'inbox'"
        case .sent: viewMembership = "role = 'sent'"
        case .junk: viewMembership = "role = 'junk'"
        case .folder(let mailbox):
            viewMembership = "mailbox = ?"
            viewParams = [mailbox]
        default: break
        }
        var having: [String] = []
        if options.unreadOnly { having.append("unread > 0") }
        if options.attachmentsOnly { having.append("any_attachment > 0") }
        if options.starredOnly { having.append("any_flagged > 0") }
        let havingClause = having.isEmpty ? "" : "HAVING " + having.joined(separator: " AND ")
        let order = switch options.sort {
        case .newest: "shown DESC"
        case .oldest: "shown ASC"
        case .sender: "LOWER(shown_sender) ASC, shown DESC"
        case .subject: "LOWER(shown_subject) ASC, shown DESC"
        case .unreadFirst: "(unread > 0) DESC, shown DESC"
        }
        params += viewParams
        params.append(limit)
        // SQLite takes bare columns (subject, snippet, sender) from the row holding MAX(date), i.e. the latest
        // message, but only when MAX is the query's single min/max aggregate; the rest therefore use SUM.
        let viewKeys = viewMembership.map { "SELECT key FROM membership WHERE \($0)" } ?? "SELECT NULL WHERE 0"
        let rows = try db.query("""
        WITH agg AS (
            SELECT thread_id, account, subject, snippet, COALESCE(from_name, from_addr, '') AS latest_sender,
                   COALESCE(from_addr, '') AS latest_address,
                   MAX(date) AS latest, COUNT(*) AS count,
                   SUM(CASE WHEN seen = 0 THEN 1 ELSE 0 END) AS unread,
                   SUM(flagged) AS any_flagged,
                   SUM(CASE WHEN attachments_json != '[]' THEN 1 ELSE 0 END) AS any_attachment,
                   GROUP_CONCAT(labels_json, '\u{1f}') AS all_labels,
                   GROUP_CONCAT(COALESCE(from_name, from_addr) || char(30) || COALESCE(from_addr, ''), '\u{1f}') AS people
            FROM messages \(whereClause)
            GROUP BY thread_id \(havingClause)
        ),
        view AS (
            SELECT thread_id, subject AS v_subject, snippet AS v_snippet,
                   COALESCE(from_name, from_addr, '') AS v_sender, COALESCE(from_addr, '') AS v_address, MAX(date) AS v_date
            FROM messages WHERE key IN (\(viewKeys))
            GROUP BY thread_id
        ),
        mine AS (
            SELECT thread_id, subject AS s_subject, MAX(date) AS s_date
            FROM messages WHERE key IN (SELECT key FROM membership WHERE role = 'sent')
            GROUP BY thread_id
        ),
        received AS (
            SELECT thread_id, MAX(date) AS r_date
            FROM messages WHERE key NOT IN (SELECT key FROM membership WHERE role = 'sent')
            GROUP BY thread_id
        )
        SELECT agg.*,
               COALESCE(v_subject, subject) AS shown_subject, COALESCE(v_snippet, snippet) AS shown_snippet,
               COALESCE(v_sender, latest_sender) AS shown_sender, COALESCE(v_address, latest_address) AS shown_address,
               COALESCE(v_date, latest) AS shown,
               CASE WHEN v_date IS NOT NULL AND latest > v_date THEN 1 ELSE 0 END AS answered,
               CASE WHEN s_date IS NULL OR r_date IS NULL OR s_date <= r_date THEN 0
                    WHEN LOWER(s_subject) LIKE 'fwd:%' OR LOWER(s_subject) LIKE 'fw:%' THEN 2
                    ELSE 1 END AS last_action
        FROM agg LEFT JOIN view USING (thread_id) LEFT JOIN mine USING (thread_id) LEFT JOIN received USING (thread_id)
        ORDER BY \(order) LIMIT ?
        """, params)
        return rows.map { row in
            // "Name␞address" pairs, one per message; keep the first of each name.
            var seen = Set<String>()
            let pairs = (row.string("people") ?? "").split(separator: "\u{1f}").map { item -> (String, String) in
                let parts = item.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                return (parts.first ?? "", parts.count > 1 ? parts[1].lowercased() : "")
            }.filter { seen.insert($0.0).inserted }
            let people = pairs.map(\.0)
            return ThreadSummary(
                id: row.string("thread_id") ?? "",
                accountID: row.string("account") ?? "",
                subject: row.string("shown_subject") ?? "",
                participants: people,
                participantAddresses: pairs.map(\.1),
                date: Date(timeIntervalSince1970: row.double("shown")),
                messageCount: row.int("count"),
                unreadCount: row.int("unread"),
                snippet: row.string("shown_snippet") ?? "",
                latestSender: row.string("shown_sender") ?? "",
                latestSenderAddress: row.string("shown_address") ?? "",
                hasLaterMessage: row.int("answered") != 0,
                lastAction: row.int("last_action") == 2 ? .forwarded : row.int("last_action") == 1 ? .replied : nil,
                flagged: row.int("any_flagged") != 0,
                hasAttachments: row.int("any_attachment") != 0,
                tags: Self.tags(fromConcatenated: row.string("all_labels"))
            )
        }
    }

    private static func tags(fromConcatenated value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.split(separator: "\u{1f}").flatMap { decode([String].self, String($0)) ?? [] }
            .filter(Tags.isUserTag)
            .filter { seen.insert(Tags.fold($0)).inserted }
    }

    /// All user tags in use, for the sidebar.
    /// All user tags in use, one spelling per tag (the most used one), for the sidebar and pickers.
    /// The faster check (no index-content comparison); "ok" when the database is healthy.
    public func quickCheck() throws -> String {
        try db.query("PRAGMA quick_check").compactMap { $0.values.values.first.flatMap { value -> String? in
            if case .text(let text) = value { return text }
            return nil
        } }.joined(separator: "\n")
    }

    /// SQLite's own consistency check; "ok" when the database is healthy.
    public func integrityCheck() throws -> String {
        let rows = try db.query("PRAGMA integrity_check")
        return rows.compactMap { $0.values.values.first.flatMap { value -> String? in
            if case .text(let text) = value { return text }
            return nil
        } }.joined(separator: "\n")
    }

    /// Messages per account, for the storage overview.
    public func messageCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try db.query("SELECT account, COUNT(*) AS n FROM messages GROUP BY account") {
            if let account = row.string("account") { counts[account] = row.int("n") }
        }
        return counts
    }

    public func allTags(accountID: String? = nil) throws -> [String] {
        let rows = try db.query("""
        SELECT j.value AS tag, COUNT(*) AS uses FROM messages m, json_each(m.labels_json) j
        WHERE (? IS NULL OR m.account = ?) GROUP BY j.value
        """, [accountID, accountID])
        var best: [String: (tag: String, uses: Int)] = [:]
        for row in rows {
            guard let tag = row.string("tag"), Tags.isUserTag(tag) else { continue }
            let key = Tags.fold(tag)
            if (best[key]?.uses ?? -1) < row.int("uses") { best[key] = (tag, row.int("uses")) }
        }
        return best.values.map(\.tag).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Number of threads carrying each tag (Trash excluded), keyed by `Tags.fold(tag)`.
    public func tagCounts(accountID: String? = nil) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for row in try db.query("""
        SELECT mm_fold(j.value) AS tag, COUNT(DISTINCT m.thread_id) AS threads FROM messages m, json_each(m.labels_json) j
        WHERE (? IS NULL OR m.account = ?)
          AND m.thread_id NOT IN (SELECT x.thread_id FROM messages x JOIN membership b ON b.key = x.key WHERE b.role = 'trash')
        GROUP BY mm_fold(j.value)
        """, [accountID, accountID]) {
            if let tag = row.string("tag") { result[tag] = row.int("threads") }
        }
        return result
    }

    public func setFlagged(keys: [String], _ flagged: Bool) throws {
        for key in keys { try db.execute("UPDATE messages SET flagged = ? WHERE key = ?", [flagged, key]) }
    }

    public func setSeen(keys: [String], _ seen: Bool) throws {
        for key in keys { try db.execute("UPDATE messages SET seen = ? WHERE key = ?", [seen, key]) }
    }

    public func setLabels(key: String, _ labels: [String]) throws {
        try db.execute("UPDATE messages SET labels_json = ? WHERE key = ?", [Self.json(labels), key])
    }

    /// Server copies of each message in a thread, grouped per message key.
    public func copies(inThread threadID: String) throws -> [(key: String, mailbox: String, uid: UInt32)] {
        try db.query("""
        SELECT b.key, b.mailbox, b.uid FROM membership b JOIN messages m ON m.key = b.key WHERE m.thread_id = ?
        """, [threadID]).map { ($0.string("key") ?? "", $0.string("mailbox") ?? "", UInt32($0.int("uid"))) }
    }

    // MARK: - Addresses

    /// Everyone in your mail (senders and recipients), with how often you wrote to them, best first.
    public func addressSuggestions(ownAddresses: [String], limit: Int = 3000) throws -> [AddressSuggestion] {
        let own = String(decoding: try JSONEncoder().encode(ownAddresses.map { $0.lowercased() }), as: UTF8.self)
        let rows = try db.query("""
        SELECT LOWER(addr) AS addr, MAX(name) AS name, COUNT(*) AS seen, SUM(sent) AS sent, MAX(date) AS last FROM (
            SELECT from_addr AS addr, from_name AS name, date, 0 AS sent FROM messages
            UNION ALL
            SELECT json_extract(j.value, '$.address'), json_extract(j.value, '$.name'), m.date,
                   CASE WHEN LOWER(m.from_addr) IN (SELECT value FROM json_each(?1)) THEN 1 ELSE 0 END
            FROM messages m, json_each(m.to_json) j
            UNION ALL
            SELECT json_extract(j.value, '$.address'), json_extract(j.value, '$.name'), m.date,
                   CASE WHEN LOWER(m.from_addr) IN (SELECT value FROM json_each(?1)) THEN 1 ELSE 0 END
            FROM messages m, json_each(m.cc_json) j
        )
        WHERE addr IS NOT NULL AND addr LIKE '%@%' AND LOWER(addr) NOT IN (SELECT value FROM json_each(?1))
        GROUP BY LOWER(addr)
        """, [own])
        let suggestions = rows.map {
            AddressSuggestion(address: $0.string("addr") ?? "", name: $0.string("name"),
                              sent: $0.int("sent"), seen: $0.int("seen"), lastSeen: Date(timeIntervalSince1970: $0.double("last")))
        }
        return Array(suggestions.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Snoozes

    public func setSnooze(threadID: String, account: String, until: Date) throws {
        try db.execute("INSERT OR REPLACE INTO snoozes (thread_id, account, wake_at) VALUES (?, ?, ?)",
                       [threadID, account, until.timeIntervalSince1970])
    }

    public func removeSnooze(threadID: String) throws {
        try db.execute("DELETE FROM snoozes WHERE thread_id = ?", [threadID])
    }

    /// Wake-up time of every snoozed thread.
    public func snoozes() throws -> [String: Date] {
        var result: [String: Date] = [:]
        for row in try db.query("SELECT thread_id, wake_at FROM snoozes") {
            result[row.string("thread_id") ?? ""] = Date(timeIntervalSince1970: row.double("wake_at"))
        }
        return result
    }

    // MARK: People

    /// How much mail you have with an address, for the person card.
    public func personStats(address: String, ownAddresses: [String]) throws -> PersonStats {
        let own = String(decoding: try JSONEncoder().encode(ownAddresses.map { $0.lowercased() }), as: UTF8.self)
        let like = "%\"" + address.lowercased() + "\"%"
        let row = try db.query("""
        SELECT COUNT(*) AS messages, COUNT(DISTINCT thread_id) AS threads, MIN(date) AS first, MAX(date) AS last,
               MAX(CASE WHEN LOWER(from_addr) = ? THEN date END) AS last_from,
               MAX(CASE WHEN LOWER(COALESCE(from_addr, '')) IN (SELECT value FROM json_each(?)) THEN date END) AS last_to
        FROM messages
        WHERE LOWER(from_addr) = ? OR LOWER(to_json) LIKE ? OR LOWER(cc_json) LIKE ?
        """, [address.lowercased(), own, address.lowercased(), like, like]).first
        func date(_ key: String) -> Date? {
            guard let row, row.values[key].map({ if case .null = $0 { false } else { true } }) == true else { return nil }
            return Date(timeIntervalSince1970: row.double(key))
        }
        return PersonStats(messages: row?.int("messages") ?? 0, threads: row?.int("threads") ?? 0,
                           first: date("first"), last: date("last"), lastFromThem: date("last_from"), lastToThem: date("last_to"))
    }

    // MARK: Calendar events from invitations

    /// Remembers the meeting in a message (newer messages about the same UID replace it; a reply does not).
    public func upsertEvent(_ invite: CalendarInvite, message: StoredMessage) throws {
        guard invite.method != .reply else { return }
        try db.execute("""
        INSERT OR REPLACE INTO events (uid, message_key, thread_id, account, summary, start, end_date, all_day, location, method, cancelled)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [invite.uid, message.key, message.threadID, message.accountID, invite.summary,
               invite.start?.timeIntervalSince1970, invite.end?.timeIntervalSince1970, invite.isAllDay ? 1 : 0,
               invite.location, invite.method.rawValue, invite.isCancelled ? 1 : 0])
    }

    /// Meetings that overlap the interval, earliest first.
    public func events(from start: Date, to end: Date) throws -> [StoredEvent] {
        try db.query("""
        SELECT * FROM events WHERE start IS NOT NULL AND start < ? AND COALESCE(end_date, start) >= ?
        ORDER BY start
        """, [end.timeIntervalSince1970, start.timeIntervalSince1970]).map { row in
            StoredEvent(uid: row.string("uid") ?? "", messageKey: row.string("message_key") ?? "",
                        threadID: row.string("thread_id") ?? "", accountID: row.string("account") ?? "",
                        summary: row.string("summary") ?? "", start: Date(timeIntervalSince1970: row.double("start")),
                        end: row.values["end_date"].flatMap { if case .real(let v) = $0 { Date(timeIntervalSince1970: v) } else { nil } },
                        isAllDay: row.int("all_day") != 0, location: row.string("location"),
                        isCancelled: row.int("cancelled") != 0)
        }
    }

    // MARK: Thread summaries (assistant)

    /// Keeps a thread's summary; `latestKey` is the newest message it covered.
    public func setSummary(_ summary: String, threadID: String, latestKey: String, created: Date = Date()) throws {
        try db.execute("INSERT OR REPLACE INTO thread_summaries (thread_id, summary, latest_key, created) VALUES (?, ?, ?, ?)",
                       [threadID, summary, latestKey, created.timeIntervalSince1970])
    }

    public func summary(threadID: String) throws -> (text: String, latestKey: String, created: Date)? {
        try db.query("SELECT * FROM thread_summaries WHERE thread_id = ?", [threadID]).first.map {
            ($0.string("summary") ?? "", $0.string("latest_key") ?? "", Date(timeIntervalSince1970: $0.double("created")))
        }
    }

    public func removeSummary(threadID: String) throws {
        try db.execute("DELETE FROM thread_summaries WHERE thread_id = ?", [threadID])
    }

    // MARK: Follow-ups ("pripomenúť, ak neodpovie")

    public func setFollowUp(threadID: String, account: String, due: Date, since: Date) throws {
        try db.execute("INSERT OR REPLACE INTO follow_ups (thread_id, account, due, since, fired) VALUES (?, ?, ?, ?, 0)",
                       [threadID, account, due.timeIntervalSince1970, since.timeIntervalSince1970])
    }

    public func removeFollowUp(threadID: String) throws {
        try db.execute("DELETE FROM follow_ups WHERE thread_id = ?", [threadID])
    }

    public func markFollowUpFired(threadID: String) throws {
        try db.execute("UPDATE follow_ups SET fired = 1 WHERE thread_id = ?", [threadID])
    }

    public func followUps() throws -> [String: FollowUp] {
        var result: [String: FollowUp] = [:]
        for row in try db.query("SELECT * FROM follow_ups") {
            let id = row.string("thread_id") ?? ""
            result[id] = FollowUp(threadID: id, accountID: row.string("account") ?? "",
                                  due: Date(timeIntervalSince1970: row.double("due")),
                                  since: Date(timeIntervalSince1970: row.double("since")), fired: row.int("fired") != 0)
        }
        return result
    }

    /// Whether someone other than you wrote in the thread after `date` (the follow-up is answered).
    public func hasReply(threadID: String, after date: Date, ownAddresses: [String]) throws -> Bool {
        let own = String(decoding: try JSONEncoder().encode(ownAddresses.map { $0.lowercased() }), as: UTF8.self)
        return try !db.query("""
        SELECT 1 FROM messages WHERE thread_id = ? AND date > ?
          AND LOWER(COALESCE(from_addr, '')) NOT IN (SELECT value FROM json_each(?))
          AND key NOT IN (SELECT key FROM membership WHERE role = 'sent')
        LIMIT 1
        """, [threadID, date.timeIntervalSince1970, own]).isEmpty
    }

    /// Snoozed threads whose time has come.
    public func dueSnoozes(at date: Date = Date()) throws -> [(threadID: String, account: String)] {
        try db.query("SELECT thread_id, account FROM snoozes WHERE wake_at <= ?", [date.timeIntervalSince1970]).map {
            ($0.string("thread_id") ?? "", $0.string("account") ?? "")
        }
    }

    /// Threads with unread messages per server folder of an account, for the sidebar.
    public func unreadThreadsByMailbox(account: String) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for row in try db.query("""
        SELECT b.mailbox, COUNT(DISTINCT m.thread_id) AS unread FROM membership b JOIN messages m ON m.key = b.key
        WHERE b.account = ? AND m.seen = 0 GROUP BY b.mailbox
        """, [account]) {
            result[row.string("mailbox") ?? ""] = row.int("unread")
        }
        return result
    }

    /// Number of inbox threads with unread messages, per account.
    public func unreadInboxThreadsByAccount() throws -> [String: Int] {
        var result: [String: Int] = [:]
        for row in try db.query("""
        SELECT account, COUNT(DISTINCT thread_id) AS unread FROM messages
        WHERE seen = 0 AND thread_id IN (SELECT m.thread_id FROM messages m JOIN membership b ON b.key = m.key WHERE b.role = 'inbox')
        GROUP BY account
        """) {
            result[row.string("account") ?? ""] = row.int("unread")
        }
        return result
    }

    public func threadFilename(_ threadID: String) throws -> String? {
        try db.query("SELECT filename FROM thread_files WHERE thread_id = ?", [threadID]).first?.string("filename")
    }

    public func setThreadFilename(_ threadID: String, _ filename: String) throws {
        try db.execute("INSERT OR REPLACE INTO thread_files (thread_id, filename) VALUES (?, ?)", [threadID, filename])
    }

    public func isFilenameTaken(_ filename: String, byOtherThan threadID: String) throws -> Bool {
        try !db.query("SELECT 1 FROM thread_files WHERE filename = ? AND thread_id != ?", [filename, threadID]).isEmpty
    }

    // MARK: - Mailbox membership

    /// What the mailbox looked like after the last complete sync; nil forces a full pass.
    public func mailboxSnapshot(account: String, mailbox: String) throws -> MailboxSnapshot? {
        try db.query("SELECT * FROM mailbox_snapshot WHERE account = ? AND mailbox = ?", [account, mailbox]).first.map {
            MailboxSnapshot(uidValidity: UInt32($0.int("uid_validity")), uidNext: UInt32($0.int("uid_next")),
                            count: UInt32($0.int("message_count")), modSeq: UInt64($0.int("modseq")))
        }
    }

    public func setMailboxSnapshot(_ snapshot: MailboxSnapshot, account: String, mailbox: String) throws {
        try db.execute("""
        INSERT OR REPLACE INTO mailbox_snapshot (account, mailbox, uid_validity, uid_next, message_count, modseq)
        VALUES (?, ?, ?, ?, ?, ?)
        """, [account, mailbox, Int(snapshot.uidValidity), Int(snapshot.uidNext), Int(snapshot.count), Int(snapshot.modSeq)])
    }

    /// Forgets the snapshots so the next sync looks at every mailbox again (e.g. after a policy change).
    public func clearMailboxSnapshots(account: String) throws {
        try db.execute("DELETE FROM mailbox_snapshot WHERE account = ?", [account])
    }

    public func uidValidity(account: String, mailbox: String) throws -> UInt32? {
        try db.query("SELECT uid_validity FROM mailbox_state WHERE account = ? AND mailbox = ?", [account, mailbox])
            .first.map { UInt32($0.int("uid_validity")) }
    }

    public func setUIDValidity(_ value: UInt32, account: String, mailbox: String) throws {
        try db.execute("INSERT OR REPLACE INTO mailbox_state (account, mailbox, uid_validity) VALUES (?, ?, ?)",
                       [account, mailbox, value])
    }

    public func clearMembership(account: String, mailbox: String) throws {
        try db.execute("DELETE FROM membership WHERE account = ? AND mailbox = ?", [account, mailbox])
    }

    public func membership(account: String, mailbox: String) throws -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        for row in try db.query("SELECT uid, key FROM membership WHERE account = ? AND mailbox = ?", [account, mailbox]) {
            result[UInt32(row.int("uid"))] = row.string("key")
        }
        return result
    }

    public func addMembership(account: String, mailbox: String, role: MailboxRole?, uid: UInt32, key: String) throws {
        try db.execute("INSERT OR REPLACE INTO membership (account, mailbox, role, uid, key) VALUES (?, ?, ?, ?, ?)",
                       [account, mailbox, role?.rawValue, uid, key])
    }

    public func removeMembership(account: String, mailbox: String, uids: [UInt32]) throws {
        for uid in uids {
            try db.execute("DELETE FROM membership WHERE account = ? AND mailbox = ? AND uid = ?", [account, mailbox, uid])
        }
    }

    /// UIDs of a thread's messages in the mailbox with the given role, plus whether each is unread.
    public func uids(inThread threadID: String, role: MailboxRole) throws -> [(mailbox: String, uid: UInt32, key: String, seen: Bool)] {
        try db.query("""
        SELECT b.mailbox, b.uid, b.key, m.seen FROM membership b JOIN messages m ON m.key = b.key
        WHERE m.thread_id = ? AND b.role = ?
        """, [threadID, role.rawValue]).map {
            ($0.string("mailbox") ?? "", UInt32($0.int("uid")), $0.string("key") ?? "", $0.int("seen") != 0)
        }
    }

    /// Every server copy of a thread's messages, in any synced mailbox.
    /// Every server copy of a message (a message can be in several mailboxes, or twice in one).
    public func copies(ofKey key: String) throws -> [(mailbox: String, uid: UInt32, role: MailboxRole)] {
        try db.query("SELECT mailbox, uid, role FROM membership WHERE key = ?", [key]).compactMap { row in
            row.string("role").flatMap(MailboxRole.init(rawValue:)).map { (row.string("mailbox") ?? "", UInt32(row.int("uid")), $0) }
        }
    }

    public func allUIDs(inThread threadID: String) throws -> [(mailbox: String, uid: UInt32, role: MailboxRole?)] {
        try db.query("""
        SELECT b.mailbox, b.uid, b.role FROM membership b JOIN messages m ON m.key = b.key WHERE m.thread_id = ?
        """, [threadID]).map {
            ($0.string("mailbox") ?? "", UInt32($0.int("uid")), $0.string("role").flatMap(MailboxRole.init(rawValue:)))
        }
    }

    /// Removes a thread from the index and returns its raw message paths and note filename for cleanup.
    public func deleteThread(_ threadID: String) throws -> (rawPaths: [String], filename: String?) {
        let rows = try db.query("SELECT key, raw_path FROM messages WHERE thread_id = ?", [threadID])
        let filename = try threadFilename(threadID)
        try db.transaction {
            for row in rows {
                guard let key = row.string("key") else { continue }
                try db.execute("DELETE FROM membership WHERE key = ?", [key])
                try db.execute("DELETE FROM messages_fts WHERE key = ?", [key])
                try db.execute("DELETE FROM messages WHERE key = ?", [key])
            }
            try db.execute("DELETE FROM thread_files WHERE thread_id = ?", [threadID])
        }
        return (rows.compactMap { $0.string("raw_path") }, filename)
    }

    // MARK: - Helpers

    /// Turns user input into an FTS5 prefix query: `jan fakt` -> `"jan"* "fakt"*`.
    static func ftsQuery(_ input: String) -> String? {
        let tokens = input.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "[]"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ string: String?) -> T? {
        guard let string else { return nil }
        return try? JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private static func message(_ row: SQLRow) -> StoredMessage {
        StoredMessage(
            key: row.string("key") ?? "",
            accountID: row.string("account") ?? "",
            messageID: row.string("message_id"),
            threadID: row.string("thread_id") ?? "",
            subject: row.string("subject") ?? "",
            from: row.string("from_addr").map { EmailAddress(name: row.string("from_name"), address: $0) },
            to: decode([EmailAddress].self, row.string("to_json")) ?? [],
            cc: decode([EmailAddress].self, row.string("cc_json")) ?? [],
            date: Date(timeIntervalSince1970: row.double("date")),
            snippet: row.string("snippet") ?? "",
            bodyText: row.string("body_text") ?? "",
            hasHTML: row.int("has_html") != 0,
            seen: row.int("seen") != 0,
            flagged: row.int("flagged") != 0,
            labels: decode([String].self, row.string("labels_json")) ?? [],
            rawPath: row.string("raw_path") ?? "",
            inReplyTo: row.string("in_reply_to"),
            references: decode([String].self, row.string("references_json")) ?? [],
            attachments: decode([String].self, row.string("attachments_json")) ?? []
        )
    }
}
