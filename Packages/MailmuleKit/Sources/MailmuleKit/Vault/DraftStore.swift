import Foundation

/// An unsent message kept in the vault.
public struct SavedDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var accountID: String
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]
    public var updated: Date
    /// When set, Mailmule sends the draft at this time (scheduled send).
    public var scheduledAt: Date?
    /// Message-ID of the copy in the server's Drafts folder (uploaded by Mailmule or written on another device).
    public var serverMessageID: String?
    /// When the server copy matched this draft; later local edits still need uploading.
    public var serverSynced: Date?
    /// Waiting in the outbox after sending failed for lack of connection; `scheduledAt` is the next try.
    public var outbox = false
    public var sendAttempts = 0
    /// Why the last try failed.
    public var sendError: String?

    public init(id: UUID = UUID(), accountID: String, to: String = "", cc: String = "", subject: String = "",
                body: String = "", inReplyTo: String? = nil, references: [String] = [],
                attachments: [OutgoingAttachment] = [], updated: Date = Date(), scheduledAt: Date? = nil) {
        self.id = id
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.updated = updated
        self.scheduledAt = scheduledAt
    }

    /// The draft as a MIME message for the server's Drafts folder, under its stable Message-ID.
    public func mimeMessage(from: EmailAddress) -> (data: Data, messageID: String) {
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "mailmule.local"
        let messageID = serverMessageID ?? "draft-\(id.uuidString.lowercased())@\(domain)"
        let draft = Draft(from: from, to: AddressParser.parseList(to), cc: AddressParser.parseList(cc), subject: subject,
                          markdown: body, inReplyTo: inReplyTo, references: references, attachments: attachments)
        return (MessageBuilder.build(draft, date: updated, messageID: messageID).data, messageID)
    }

    /// A draft written elsewhere (phone, Gmail on the web), taken from the server's Drafts folder.
    public init(serverDraft data: Data, accountID: String) {
        let mime = MIMEMessage(data: data)
        let field = { (list: [EmailAddress]) in
            list.map { address in address.name.map { "\"\($0)\" <\(address.address)>" } ?? address.address }.joined(separator: ", ")
        }
        let attachments = mime.root.leaves.filter { $0.isAttachment && $0.stubSize == nil }.map {
            OutgoingAttachment(filename: $0.filename ?? "príloha", mimeType: $0.mimeType, data: $0.decodedBody)
        }
        self.init(accountID: accountID, to: field(mime.to), cc: field(mime.cc), subject: mime.subject,
                  body: mime.bestText.trimmingCharacters(in: .whitespacesAndNewlines),
                  inReplyTo: mime.inReplyTo, references: mime.references, attachments: attachments,
                  updated: mime.bestDate ?? Date())
        serverMessageID = mime.messageID
        serverSynced = Date()
    }

    /// Nothing worth keeping was written.
    public var isBlank: Bool {
        [to, cc, subject, body].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && attachments.isEmpty
    }
}

/// Drafts as files in the vault:
///
///     drafts/<id>.md            frontmatter (recipients, subject, reply headers) + Markdown body
///     drafts/<id>/<attachment>  attached files
public struct DraftStore: Sendable {
    public let directory: URL

    public init(vault: MailVault) {
        directory = vault.root.appending(path: "drafts", directoryHint: .isDirectory)
    }

    private func noteURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).md")
    }

    private func attachmentsURL(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// File name safe to use inside the draft folder (no path separators, no hidden files).
    static func safeFilename(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "priloha" : cleaned
    }

    public func save(_ draft: SavedDraft) throws {
        var draft = draft
        for index in draft.attachments.indices {
            draft.attachments[index].filename = Self.safeFilename(draft.attachments[index].filename)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["---"]
        lines.append("account: \(Self.json(draft.accountID))")
        lines.append("to: \(Self.json(draft.to))")
        lines.append("cc: \(Self.json(draft.cc))")
        lines.append("subject: \(Self.json(draft.subject))")
        if let inReplyTo = draft.inReplyTo { lines.append("in_reply_to: \(Self.json(inReplyTo))") }
        lines.append("references: \(Self.json(draft.references))")
        lines.append("attachments: \(Self.json(draft.attachments.map(\.filename)))")
        lines.append("updated: \(Self.json(ISO8601DateFormatter().string(from: draft.updated)))")
        if let serverMessageID = draft.serverMessageID { lines.append("server_id: \(Self.json(serverMessageID))") }
        if let serverSynced = draft.serverSynced {
            lines.append("server_synced: \(Self.json(ISO8601DateFormatter().string(from: serverSynced)))")
        }
        if let scheduledAt = draft.scheduledAt {
            lines.append("scheduled: \(Self.json(ISO8601DateFormatter().string(from: scheduledAt)))")
        }
        if draft.outbox {
            lines.append("outbox: true")
            lines.append("send_attempts: \(draft.sendAttempts)")
        }
        if let sendError = draft.sendError { lines.append("send_error: \(Self.json(sendError))") }
        lines.append("---")
        lines.append(draft.body)
        try Data(lines.joined(separator: "\n").utf8).write(to: noteURL(draft.id), options: .atomic)

        // Attachments: write current files, remove ones that were taken out of the draft.
        let folder = attachmentsURL(draft.id)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let wanted = Set(draft.attachments.map(\.filename))
        if !draft.attachments.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for attachment in draft.attachments {
            let url = folder.appending(path: attachment.filename)
            if existing.contains(attachment.filename), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size == attachment.data.count {
                continue
            }
            try attachment.data.write(to: url, options: .atomic)
        }
        for name in existing.subtracting(wanted) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        if draft.attachments.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// All drafts, newest first. Attachment data is loaded too; drafts are few and small.
    public func all() -> [SavedDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .compactMap { load($0) }
            .sorted { $0.updated > $1.updated }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: noteURL(id))
        try? FileManager.default.removeItem(at: attachmentsURL(id))
    }

    private func load(_ url: URL) -> SavedDraft? {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: Any] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
        }
        lines.removeSubrange(0...end)
        let body = lines.joined(separator: "\n")

        let folder = attachmentsURL(id)
        let attachments = ((fields["attachments"] as? [String]) ?? []).compactMap { name -> OutgoingAttachment? in
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return OutgoingAttachment(filename: name, data: data)
        }
        let updated = (fields["updated"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date.distantPast
        var draft = SavedDraft(
            id: id,
            accountID: fields["account"] as? String ?? "",
            to: fields["to"] as? String ?? "",
            cc: fields["cc"] as? String ?? "",
            subject: fields["subject"] as? String ?? "",
            body: body,
            inReplyTo: fields["in_reply_to"] as? String,
            references: fields["references"] as? [String] ?? [],
            attachments: attachments,
            updated: updated,
            scheduledAt: (fields["scheduled"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
        draft.serverMessageID = fields["server_id"] as? String
        draft.serverSynced = (fields["server_synced"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        draft.outbox = fields["outbox"] as? Bool ?? false
        draft.sendAttempts = fields["send_attempts"] as? Int ?? 0
        draft.sendError = fields["send_error"] as? String
        return draft
    }

    /// JSON values are valid YAML, so the frontmatter stays readable in Obsidian.
    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "\"\""
    }
}
