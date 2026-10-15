import Foundation
import Testing
@testable import MailmuleKit

// MARK: - IMAP

@Test func parsesFetchWithLiteralAndGmailAttributes() throws {
    let body = "Subject: Ahoj\r\n\r\nTelo"
    let raw = "* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) X-GM-THRID 1780000000000000001 X-GM-LABELS (\"\\\\Inbox\" Projekt \"Moje veci\") BODY[] {\(body.utf8.count)}\r\n\(body))\r\n"
    let response = try IMAPParser.parse(Data(raw.utf8))
    guard case .numbered(3, "FETCH", let values) = response, let attrs = values.first?.list?.fetchAttributes() else {
        Issue.record("unexpected \(response)")
        return
    }
    let result = IMAPFetchResult(uid: 42, attributes: attrs)
    #expect(attrs["UID"]?.text == "42")
    #expect(result.flags == ["\\Seen", "\\Flagged"])
    #expect(result.gmailThreadID == "1780000000000000001")
    #expect(result.gmailLabels == ["\\Inbox", "Projekt", "Moje veci"])
    #expect(result.body().map { String(decoding: $0, as: UTF8.self) } == body)
}

@Test func parsesHeaderFieldsSection() throws {
    let header = "Message-ID: <abc@x>\r\n\r\n"
    let raw = "* 1 FETCH (UID 7 BODY[HEADER.FIELDS (MESSAGE-ID)] {\(header.utf8.count)}\r\n\(header))\r\n"
    guard case .numbered(_, _, let values) = try IMAPParser.parse(Data(raw.utf8)),
          let attrs = values.first?.list?.fetchAttributes() else {
        Issue.record("parse failed")
        return
    }
    let result = IMAPFetchResult(uid: 7, attributes: attrs)
    #expect(result.body("HEADER").map { String(decoding: $0, as: UTF8.self) } == header)
}

@Test func parsesListAndStatus() throws {
    let list = try IMAPParser.parse(Data("* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Odoslan&AOE- po&AWE-ta\"\r\n".utf8))
    guard case .data("LIST", let values) = list else {
        Issue.record("unexpected \(list)")
        return
    }
    #expect(values[2].text == "[Gmail]/Odoslan&AOE- po&AWE-ta")

    let status = try IMAPParser.parse(Data("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n".utf8))
    guard case .status(nil, "OK", "UIDVALIDITY 3857529045", "UIDs valid") = status else {
        Issue.record("unexpected \(status)")
        return
    }

    let tagged = try IMAPParser.parse(Data("M4 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n".utf8))
    guard case .status("M4", "NO", "AUTHENTICATIONFAILED", _) = tagged else {
        Issue.record("unexpected \(tagged)")
        return
    }
}

@Test func literalLengthAndUIDSet() {
    #expect(IMAPClient.literalLength(atEndOf: Data("* 1 FETCH (BODY[] {123}\r\n".utf8)) == 123)
    #expect(IMAPClient.literalLength(atEndOf: Data("* OK done\r\n".utf8)) == nil)
    #expect(IMAPClient.uidSet([9, 1, 2, 3, 5, 10, 11, 12]) == "1:3,5,9:12")
}

// MARK: - MIME

@Test func parsesMultipartWithEncodings() {
    let raw = """
    From: =?utf-8?Q?J=C3=A1n_Nov=C3=A1k?= <jan@example.sk>\r
    To: "Peter" <peter@example.com>, eva@example.com\r
    Subject: =?windows-1250?Q?Fakt=FAra_za_september?=\r
    Date: Mon, 12 Oct 2026 09:14:00 +0200 (CEST)\r
    Message-ID: <msg-1@example.sk>\r
    References: <root@example.sk> <msg-0@example.sk>\r
    Content-Type: multipart/mixed; boundary="outer"\r
    \r
    --outer\r
    Content-Type: multipart/alternative; boundary=inner\r
    \r
    --inner\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Ahoj, posielam fakt=C3=BAru.=\r
     Pekn=C3=BD de=C5=88.\r
    --inner\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <p>Ahoj</p>\r
    --inner--\r
    --outer\r
    Content-Type: application/pdf; name="faktura.pdf"\r
    Content-Disposition: attachment; filename*=utf-8''fakt%C3%BAra.pdf\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERi0=\r
    --outer--\r

    """
    let message = MIMEMessage(data: Data(raw.utf8))
    #expect(message.from == EmailAddress(name: "Ján Novák", address: "jan@example.sk"))
    #expect(message.to.map(\.address) == ["peter@example.com", "eva@example.com"])
    #expect(message.subject == "Faktúra za september")
    #expect(message.messageID == "msg-1@example.sk")
    #expect(message.references == ["root@example.sk", "msg-0@example.sk"])
    #expect(message.plainText == "Ahoj, posielam faktúru. Pekný deň.")
    #expect(message.html == "<p>Ahoj</p>")
    #expect(message.attachments == [Attachment(filename: "faktúra.pdf", mimeType: "application/pdf", size: 5)])
    #expect(message.date == ISO8601DateFormatter().date(from: "2026-10-12T07:14:00Z"))
}

@Test func encodedWordsJoinAdjacent() {
    #expect(EncodedWord.decode("=?UTF-8?B?xI1v?= =?UTF-8?B?IGplIG5vdsOp?=") == "čo je nové")
    #expect(EncodedWord.decode("Re: =?iso-8859-2?Q?Pon=FAka?= pre vás") == "Re: Ponúka pre vás")
}

@Test func builtMessageRoundTrips() {
    let draft = Draft(
        from: EmailAddress(name: "Ján Novák", address: "peter@example.com"),
        to: [EmailAddress(name: nil, address: "jan@example.sk")],
        subject: "Re: Faktúra za september",
        markdown: "Ahoj **Ján**,\nvďaka.\n\n> pôvodná správa",
        inReplyTo: "msg-1@example.sk",
        references: ["root@example.sk", "msg-1@example.sk"]
    )
    let (data, id) = MessageBuilder.build(draft)
    let parsed = MIMEMessage(data: data)
    #expect(parsed.subject == "Re: Faktúra za september")
    #expect(parsed.from?.name == "Ján Novák")
    #expect(parsed.messageID == id)
    #expect(parsed.inReplyTo == "msg-1@example.sk")
    #expect(parsed.plainText?.replacingOccurrences(of: "\r\n", with: "\n") == "Ahoj Ján,\nvďaka.\n\n> pôvodná správa")
    let html = parsed.html ?? ""
    #expect(html.contains("<strong>Ján</strong>"))
    #expect(html.contains("<br"))
    #expect(html.contains("<blockquote>"))
}

@Test func smtpDotStuffing() {
    let stuffed = String(decoding: SMTPClient.dotStuffed(Data("a\r\n.b\r\n".utf8)), as: UTF8.self)
    #expect(stuffed == "a\r\n..b\r\n.\r\n")
}

// MARK: - Index & vault

private func sampleMessage(key: String, thread: String, subject: String, body: String, seen: Bool = false) -> StoredMessage {
    StoredMessage(key: key, accountID: "acc", messageID: "\(key)@x", threadID: thread, subject: subject,
                  from: EmailAddress(name: "Ján Novák", address: "jan@example.sk"), to: [], cc: [],
                  date: Date(timeIntervalSince1970: Double(key.hashValue & 0xffff)), snippet: body, bodyText: body,
                  hasHTML: false, seen: seen, flagged: false, labels: [], rawPath: "", inReplyTo: nil,
                  references: [], attachments: [])
}

@Test func indexGroupsThreadsAndSearchesWithoutDiacritics() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))

    try await index.upsert(sampleMessage(key: "a", thread: "t1", subject: "Faktúra", body: "posielam faktúru"))
    try await index.upsert(sampleMessage(key: "b", thread: "t1", subject: "Re: Faktúra", body: "vďaka", seen: true))
    try await index.upsert(sampleMessage(key: "c", thread: "t2", subject: "Obed", body: "ideme na obed?"))
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 1, key: "a")

    let inbox = try await index.threads(filter: .inbox)
    #expect(inbox.map(\.id) == ["t1"])
    #expect(inbox.first?.messageCount == 2)
    #expect(inbox.first?.unreadCount == 1)
    #expect(inbox.first?.hasAttachments == false)

    let found = try await index.threads(filter: .all, search: "faktura")
    #expect(found.map(\.id) == ["t1"])

    try await index.removeMembership(account: "acc", mailbox: "INBOX", uids: [1])
    #expect(try await index.threads(filter: .inbox).isEmpty)
}

@Test func threadMarkdownLinksPeople() {
    var reply = sampleMessage(key: "b", thread: "acc:gm1", subject: "Re: Faktúra", body: "Vďaka!\n\nDňa 12. 10. Ján napísal:\n> posielam")
    reply.from = EmailAddress(name: "Peter", address: "me@example.com")
    reply.to = [EmailAddress(name: "Ján Novák", address: "jan@example.sk")]
    let markdown = ThreadMarkdown.render(
        messages: [sampleMessage(key: "a", thread: "acc:gm1", subject: "Faktúra", body: "posielam"), reply],
        ownAddresses: ["me@example.com"]
    )
    #expect(markdown.contains("  - \"[[Ján Novák]]\""))
    #expect(markdown.contains("## Ja · "))
    #expect(markdown.contains("mailmule: \"mailmule://thread/acc%3Agm1\""))
    #expect(!markdown.contains("> posielam"))
    #expect(ThreadMarkdown.filename(subject: "Re: Faktúra: 9/2026", date: Date(timeIntervalSince1970: 0)) == "1970-01-01 Faktúra 9 2026.md")
}

// MARK: - Attachments

@Test func builtMessageWithAttachmentsRoundTrips() {
    let pdf = Data((0..<5000).map { UInt8($0 % 256) })
    let draft = Draft(
        from: EmailAddress(name: "Peter", address: "peter@example.com"),
        to: [EmailAddress(name: nil, address: "jan@example.sk")],
        subject: "Faktúra",
        markdown: "V prílohe **faktúra**.",
        attachments: [
            OutgoingAttachment(filename: "faktúra september.pdf", data: pdf),
            OutgoingAttachment(filename: "notes.txt", data: Data("ahoj".utf8)),
        ]
    )
    let parsed = MIMEMessage(data: MessageBuilder.build(draft).data)
    #expect(parsed.root.mimeType == "multipart/mixed")
    #expect(parsed.plainText?.replacingOccurrences(of: "\r\n", with: "\n") == "V prílohe faktúra.")
    #expect(parsed.html?.contains("<strong>faktúra</strong>") == true)
    #expect(parsed.attachments.map(\.filename) == ["faktúra september.pdf", "notes.txt"])
    #expect(parsed.attachments.map(\.mimeType) == ["application/pdf", "text/plain"])
    let decoded = parsed.root.leaves.first { $0.filename == "faktúra september.pdf" }?.decodedBody
    #expect(decoded == pdf)
}

@Test func mimeTypeFromFilename() {
    #expect(OutgoingAttachment.mimeType(forFilename: "foto.JPG") == "image/jpeg")
    #expect(OutgoingAttachment.mimeType(forFilename: "neznamy") == "application/octet-stream")
}

@Test func plainTextPartHasNoMarkdownSyntax() {
    let markdown = """
    Ahoj **Ján**,
    posielam *faktúru* a [cenník](https://example.com).

    ## Zhrnutie
    - termín: `piatok`
    - suma: **120 €**

    > pôvodná správa
    """
    let plain = MarkdownRenderer.plainText(from: markdown)
    #expect(plain == """
    Ahoj Ján,
    posielam faktúru a cenník (https://example.com).

    Zhrnutie

    - termín: piatok
    - suma: 120 €

    > pôvodná správa
    """)
}

@Test func parsesNamespaceResponse() throws {
    let response = try IMAPParser.parse(Data("* NAMESPACE ((\"INBOX.\" \".\")) NIL NIL\r\n".utf8))
    guard case .data("NAMESPACE", let values) = response, let first = values.first?.list?.first?.list else {
        Issue.record("unexpected \(response)")
        return
    }
    #expect(first.map(\.text) == ["INBOX.", "."])
}

@Test func deleteThreadRemovesIndexEntries() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var message = sampleMessage(key: "a", thread: "t1", subject: "Spam", body: "kúpte si")
    message.rawPath = "accounts/acc/raw/a.eml"
    try await index.upsert(message)
    try await index.upsert(sampleMessage(key: "b", thread: "t2", subject: "Iné", body: "ostáva"))
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 9, key: "a")
    try await index.setThreadFilename("t1", "2026-10-13 Spam.md")

    #expect(try await index.allUIDs(inThread: "t1").map(\.uid) == [9])
    let removed = try await index.deleteThread("t1")
    #expect(removed.rawPaths == ["accounts/acc/raw/a.eml"])
    #expect(removed.filename == "2026-10-13 Spam.md")
    #expect(try await index.threads(filter: .all).map(\.id) == ["t2"])
    #expect(try await index.threads(filter: .all, search: "kupte").isEmpty)
    #expect(try await index.membership(account: "acc", mailbox: "INBOX").isEmpty)
}

@Test func archiveAndTrashFilters() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    try await index.upsert(sampleMessage(key: "a", thread: "inbox", subject: "A", body: "a"))
    try await index.upsert(sampleMessage(key: "b", thread: "archived", subject: "B", body: "b"))
    try await index.upsert(sampleMessage(key: "c", thread: "trashed", subject: "C", body: "c"))
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 1, key: "a")
    // Gmail-style: the inbox message is in All Mail too.
    try await index.addMembership(account: "acc", mailbox: "All", role: .archive, uid: 1, key: "a")
    try await index.addMembership(account: "acc", mailbox: "All", role: .archive, uid: 2, key: "b")
    try await index.addMembership(account: "acc", mailbox: "Trash", role: .trash, uid: 3, key: "c")

    #expect(try await index.threads(filter: .inbox).map(\.id) == ["inbox"])
    #expect(try await index.threads(filter: .archive).map(\.id) == ["archived"])
    #expect(try await index.threads(filter: .trash).map(\.id) == ["trashed"])
    #expect(Set(try await index.threads(filter: .all).map(\.id)) == ["inbox", "archived"])
    #expect(try await index.allUIDs(inThread: "trashed").map(\.role) == [.trash])
}

@Test func threadsAndUnreadCountsPerAccount() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var work = sampleMessage(key: "w", thread: "work:1", subject: "Práca", body: "x")
    work.accountID = "work"
    var personal = sampleMessage(key: "p", thread: "home:1", subject: "Doma", body: "y")
    personal.accountID = "home"
    try await index.upsert(work)
    try await index.upsert(personal)
    try await index.addMembership(account: "work", mailbox: "INBOX", role: .inbox, uid: 1, key: "w")
    try await index.addMembership(account: "home", mailbox: "INBOX", role: .inbox, uid: 1, key: "p")

    #expect(Set(try await index.threads(filter: .inbox).map(\.id)) == ["work:1", "home:1"])
    #expect(try await index.threads(filter: .inbox, accountID: "work").map(\.id) == ["work:1"])
    #expect(try await index.unreadInboxThreadsByAccount() == ["work": 1, "home": 1])
}

// MARK: - Drafts

@Test func draftsRoundTripWithAttachments() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DraftStore(vault: MailVault(root: dir))

    var draft = SavedDraft(accountID: "acc", to: "\"Ján\" <jan@example.sk>", subject: "Re: Faktúra: september",
                           body: "Ahoj **Ján**,\n\n---\n> citát", inReplyTo: "msg-1@x", references: ["root@x", "msg-1@x"],
                           attachments: [OutgoingAttachment(filename: "faktúra.pdf", data: Data([1, 2, 3]))])
    try store.save(draft)
    var loaded = try #require(store.all().first)
    #expect(loaded.id == draft.id)
    #expect(loaded.to == draft.to)
    #expect(loaded.subject == draft.subject)
    #expect(loaded.body == draft.body)
    #expect(loaded.inReplyTo == "msg-1@x")
    #expect(loaded.references == ["root@x", "msg-1@x"])
    #expect(loaded.attachments.map(\.filename) == ["faktúra.pdf"])
    #expect(loaded.attachments.first?.data == Data([1, 2, 3]))

    // Removing the attachment removes its file.
    draft.attachments = []
    try store.save(draft)
    loaded = try #require(store.all().first)
    #expect(loaded.attachments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: draft.id.uuidString.lowercased()).path))

    store.delete(draft.id)
    #expect(store.all().isEmpty)
    #expect(SavedDraft(accountID: "acc", body: "  \n").isBlank)
    #expect(DraftStore.safeFilename("../../etc/passwd") == "-..-etc-passwd")
}

@Test func obsidianExportWritesAttachmentsAndEmbeds() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var message = sampleMessage(key: "m1", thread: "t1", subject: "Faktúra", body: "posielam")
    message.attachments = ["faktúra [9].pdf", "tabuľka.xlsx"]
    let thread = ExportedThread(
        filename: "2026-10-13 Faktúra.md",
        messages: [message],
        ownAddresses: [],
        attachments: [
            .init(messageKey: "m1", filename: "faktúra [9].pdf", mimeType: "application/pdf", data: Data([1])),
            .init(messageKey: "m1", filename: "tabuľka.xlsx", mimeType: "application/vnd.ms-excel", data: Data([2])),
        ]
    )
    let note = try ObsidianExporter(vaultURL: dir, folder: "Mail").export(thread: thread)
    let markdown = try String(contentsOf: note, encoding: .utf8)
    #expect(markdown.contains("![[Mail/Prílohy/2026-10-13 Faktúra/faktúra 9.pdf]]"))
    #expect(markdown.contains("- [[Mail/Prílohy/2026-10-13 Faktúra/tabuľka.xlsx]]"))
    let saved = dir.appending(path: "Mail/Prílohy/2026-10-13 Faktúra/faktúra 9.pdf")
    #expect(try Data(contentsOf: saved) == Data([1]))
}

@Test func noteFrontmatterHasNoThreadID() {
    let markdown = ThreadMarkdown.render(messages: [sampleMessage(key: "a", thread: "acc:gm1", subject: "A", body: "b")], ownAddresses: [])
    #expect(!markdown.contains("\nthread:"))
    #expect(markdown.contains("mailmule: \"mailmule://thread/acc%3Agm1\""))
}

// MARK: - Tags

@Test func modifiedUTF7RoundTrips() {
    #expect(ModifiedUTF7.encode("Odoslaná pošta") == "Odoslan&AOE- po&AWE-ta")
    #expect(ModifiedUTF7.decode("Odoslan&AOE- po&AWE-ta") == "Odoslaná pošta")
    #expect(ModifiedUTF7.decode("A&-B") == "A&B")
    for tag in ["práca", "Ďalší krok", "faktúry 2026", "R&D", "😀 emoji"] {
        let keyword = ModifiedUTF7.keyword(forTag: tag)
        #expect(!keyword.contains(" "))
        #expect(keyword.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(ModifiedUTF7.tag(forKeyword: keyword) == tag)
    }
}

@Test func starredAndTagFilters() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var a = sampleMessage(key: "a", thread: "t1", subject: "A", body: "a")
    a.labels = ["\\Inbox", "práca", "faktúry"]
    var b = sampleMessage(key: "b", thread: "t2", subject: "B", body: "b")
    b.flagged = true
    b.labels = ["osobné"]
    try await index.upsert(a)
    try await index.upsert(b)

    #expect(try await index.threads(filter: .starred).map(\.id) == ["t2"])
    #expect(try await index.threads(filter: .tag("práca")).map(\.id) == ["t1"])
    let t1 = try #require(try await index.threads(filter: .all).first { $0.id == "t1" })
    #expect(t1.tags == ["práca", "faktúry"])
    #expect(!t1.flagged)
    #expect(try await index.allTags() == ["faktúry", "osobné", "práca"])
    #expect(try await index.tagCounts() == ["\\inbox": 1, "práca": 1, "faktúry": 1, "osobné": 1])

    try await index.setFlagged(keys: ["a"], true)
    try await index.setLabels(key: "a", ["práca"])
    #expect(Set(try await index.threads(filter: .starred).map(\.id)) == ["t1", "t2"])
    #expect(try await index.threads(filter: .tag("faktúry")).isEmpty)
    #expect(Tags.fromKeywords(["\\Seen", "$Forwarded", "NonJunk", ModifiedUTF7.keyword(forTag: "Ďalší krok")]) == ["Ďalší krok"])
}

@Test func finderTagsAreWrittenLikeFinder() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "mailmule-tag-\(UUID().uuidString).md")
    FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
    defer { try? FileManager.default.removeItem(at: file) }

    FinderTagPalette.shared.update(["práca": 6])
    FinderTagPalette.shared.apply(["\\Inbox", "práca", "bez farby"], to: file)
    #expect(FinderTagIO.read(file) == [FinderTag(name: "práca", color: 6), FinderTag(name: "bez farby", color: 0)])
    // Foundation sees the same tags Finder would.
    let names = try file.resourceValues(forKeys: [.tagNamesKey]).tagNames
    #expect(names == ["práca", "bez farby"])

    FinderTagPalette.shared.apply([], to: file)
    #expect(FinderTagIO.read(file).isEmpty)
    FinderTagPalette.shared.update([:])
}

@Test func folderFilter() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    try await index.upsert(sampleMessage(key: "a", thread: "t1", subject: "Klient", body: "x"))
    try await index.upsert(sampleMessage(key: "b", thread: "t2", subject: "Iné", body: "y"))
    try await index.addMembership(account: "acc", mailbox: "INBOX.Klienti", role: .folder, uid: 1, key: "a")
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 1, key: "b")
    #expect(try await index.threads(filter: .folder("INBOX.Klienti")).map(\.id) == ["t1"])
    #expect(Set(try await index.threads(filter: .all).map(\.id)) == ["t1", "t2"])
    #expect(try await index.allUIDs(inThread: "t1").map(\.role) == [.folder])
}

// MARK: - Dates

@Test func lenientDateParsing() throws {
    let utc = { (s: String) in ISO8601DateFormatter().date(from: s)! }
    #expect(MailDate.parse("Mon, 12 Oct 2026 09:14:00 +0200 (CEST)") == utc("2026-10-12T07:14:00Z"))
    #expect(MailDate.parse("fri, 20 may 2022 12:24:43 +0200") == utc("2022-05-20T10:24:43Z"))
    #expect(MailDate.parse("20 May 2022 12:24:43 GMT") == utc("2022-05-20T12:24:43Z"))
    #expect(MailDate.parse("Fri, 20 May 22 12:24 EST") == utc("2022-05-20T17:24:00Z"))
    #expect(MailDate.parse("17-Jul-1996 02:44:25 -0700") == utc("1996-07-17T09:44:25Z"))
    // No zone: local time of this Mac.
    let local = try #require(MailDate.parse("fri, 20 may 2022 12:24:43"))
    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
    #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2022, 5, 20, 12, 24])
    #expect(MailDate.parse("nonsense") == nil)
}

@Test func dateFallsBackToReceivedHeader() {
    let raw = "Received: from a by b; Fri, 20 May 2022 12:25:43 +0200\r\nDate: garbage\r\nSubject: x\r\n\r\nbody"
    let message = MIMEMessage(data: Data(raw.utf8))
    #expect(message.date == nil)
    #expect(message.bestDate == ISO8601DateFormatter().date(from: "2022-05-20T10:25:43Z"))
    #expect(MIMEMessage.bestDate(headerData: Data(raw.utf8)) == message.bestDate)
}

// MARK: - View options

@Test func threadSortingFiltersAndLatestMessageColumns() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    func message(_ key: String, _ thread: String, _ subject: String, _ sender: String, _ date: Double,
                 seen: Bool = true, flagged: Bool = false, attachment: Bool = false) -> StoredMessage {
        var m = sampleMessage(key: key, thread: thread, subject: subject, body: subject, seen: seen)
        m.from = EmailAddress(name: sender, address: "\(key)@x.sk")
        m.date = Date(timeIntervalSince1970: date)
        m.flagged = flagged
        m.attachments = attachment ? ["a.pdf"] : []
        return m
    }
    // Thread t1: the flagged message is older; subject/sender must still come from the latest one.
    try await index.upsert(message("a1", "t1", "Pôvodná", "Zuzana", 100, flagged: true))
    try await index.upsert(message("a2", "t1", "Re: Pôvodná", "Adam", 300))
    try await index.upsert(message("b", "t2", "Bankový výpis", "Banka", 200, seen: false, attachment: true))
    try await index.upsert(message("c", "t3", "Cestovanie", "Cyril", 50))

    let newest = try await index.threads(filter: .all)
    #expect(newest.map(\.id) == ["t1", "t2", "t3"])
    #expect(newest[0].subject == "Re: Pôvodná")
    #expect(newest[0].latestSender == "Adam")
    #expect(newest[0].flagged)

    #expect(try await index.threads(filter: .all, options: .init(sort: .oldest)).map(\.id) == ["t3", "t2", "t1"])
    #expect(try await index.threads(filter: .all, options: .init(sort: .sender)).map(\.id) == ["t1", "t2", "t3"])
    #expect(try await index.threads(filter: .all, options: .init(sort: .subject)).map(\.id) == ["t2", "t3", "t1"])
    #expect(try await index.threads(filter: .all, options: .init(sort: .unreadFirst)).map(\.id) == ["t2", "t1", "t3"])
    #expect(try await index.threads(filter: .all, options: .init(unreadOnly: true)).map(\.id) == ["t2"])
    #expect(try await index.threads(filter: .all, options: .init(attachmentsOnly: true)).map(\.id) == ["t2"])
}

// MARK: - Attachments on demand

@Test func partialMessageFromBodyStructure() throws {
    let raw = #"* 1 FETCH (UID 5 RFC822.SIZE 50000 BODYSTRUCTURE ((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 120 4 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 300 8 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "alt") NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "faktura.pdf") NIL NIL "BASE64" 40000 NIL ("ATTACHMENT" ("FILENAME" "faktura.pdf")) NIL NIL) "MIXED" ("BOUNDARY" "mix") NIL NIL NIL))"# + "\r\n"
    guard case .numbered(_, "FETCH", let values) = try IMAPParser.parse(Data(raw.utf8)),
          let attrs = values.first?.list?.fetchAttributes(),
          let structure = attrs["BODYSTRUCTURE"].flatMap(BodyStructure.parse) else {
        Issue.record("parse failed")
        return
    }
    #expect(structure.leaves().map(\.section) == ["1.1", "1.2", "2"])
    #expect(structure.leaves().map(\.part.mimeType) == ["text/plain", "text/html", "application/pdf"])
    #expect(structure.leaves()[2].part.disposition == "attachment")
    #expect(structure.hasDeferrableParts)
    #expect(structure.partialFetchItems == ["BODY.PEEK[HEADER]", "BODY.PEEK[1.1.MIME]", "BODY.PEEK[1.1]",
                                            "BODY.PEEK[1.2.MIME]", "BODY.PEEK[1.2]", "BODY.PEEK[2.MIME]"])

    let fetched: [String: IMAPValue] = [
        "BODY[HEADER]": .string(Data("From: a@b.sk\r\nSubject: Faktúra\r\nContent-Type: multipart/mixed; boundary=\"mix\"\r\n\r\n".utf8)),
        "BODY[1.1.MIME]": .string(Data("Content-Type: text/plain; charset=UTF-8\r\n\r\n".utf8)),
        "BODY[1.1]": .string(Data("Dobrý deň".utf8)),
        "BODY[1.2.MIME]": .string(Data("Content-Type: text/html; charset=UTF-8\r\n\r\n".utf8)),
        "BODY[1.2]": .string(Data("<p>Dobrý deň</p>".utf8)),
        "BODY[2.MIME]": .string(Data("Content-Type: application/pdf; name=\"faktura.pdf\"\r\nContent-Disposition: attachment; filename=\"faktura.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8)),
    ]
    let data = try #require(structure.partialMessage(from: fetched))
    let message = MIMEMessage(data: data)
    #expect(message.isPartial)
    #expect(message.subject == "Faktúra")
    #expect(message.plainText == "Dobrý deň")
    #expect(message.html == "<p>Dobrý deň</p>")
    #expect(message.attachments == [Attachment(filename: "faktura.pdf", mimeType: "application/pdf", size: 40000)])
}

@Test func strippingAttachmentsKeepsTextAndNames() throws {
    let pdf = Data(repeating: 7, count: 50_000)
    let draft = Draft(from: EmailAddress(name: nil, address: "a@b.sk"), to: [EmailAddress(name: nil, address: "c@d.sk")],
                      subject: "Zmluva", markdown: "V prílohe **zmluva**.",
                      attachments: [OutgoingAttachment(filename: "zmluva.pdf", data: pdf)])
    let full = MessageBuilder.build(draft).data
    let stripped = try #require(AttachmentStripper.strip(full))
    #expect(stripped.count < full.count / 5)
    let message = MIMEMessage(data: stripped)
    #expect(message.isPartial)
    #expect(message.subject == "Zmluva")
    #expect(message.plainText?.replacingOccurrences(of: "\r\n", with: "\n") == "V prílohe zmluva.")
    #expect(message.html?.contains("<strong>zmluva</strong>") == true)
    #expect(message.attachments == [Attachment(filename: "zmluva.pdf", mimeType: "application/pdf", size: 50_000)])
    #expect(AttachmentStripper.strip(stripped) == nil)
}

@Test func removingAccountDataKeepsOtherAccounts() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var gmail = sampleMessage(key: "g", thread: "gmail:1", subject: "Gmail", body: "x")
    gmail.accountID = "gmail"
    var work = sampleMessage(key: "w", thread: "work:1", subject: "Práca", body: "y")
    work.accountID = "work"
    try await index.upsert(gmail)
    try await index.upsert(work)
    try await index.addMembership(account: "gmail", mailbox: "INBOX", role: .inbox, uid: 1, key: "g")
    try await index.setThreadFilename("gmail:1", "2026-10-14 Gmail.md")
    #expect(try await index.removeAccount("gmail") == ["2026-10-14 Gmail.md"])
    #expect(try await index.threads(filter: .all).map(\.id) == ["work:1"])
    #expect(try await index.membership(account: "gmail", mailbox: "INBOX").isEmpty)
    #expect(try await index.threads(filter: .all, search: "gmail").isEmpty)
}

@Test func junkAndStarredFilters() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    try await index.upsert(sampleMessage(key: "s", thread: "spam", subject: "Výhra", body: "x"))
    var starred = sampleMessage(key: "k", thread: "keep", subject: "Dôležité", body: "y")
    starred.flagged = true
    try await index.upsert(starred)
    try await index.addMembership(account: "acc", mailbox: "INBOX.Spam", role: .junk, uid: 1, key: "s")
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 2, key: "k")
    #expect(try await index.threads(filter: .junk).map(\.id) == ["spam"])
    #expect(try await index.threads(filter: .all).map(\.id) == ["keep"])
    #expect(try await index.threads(filter: .inbox, options: .init(starredOnly: true)).map(\.id) == ["keep"])
    #expect(try await index.unreadThreadsByMailbox(account: "acc") == ["INBOX.Spam": 1, "INBOX": 1])
    let old = try JSONDecoder().decode(ThreadListOptions.self, from: Data(#"{"sort":"oldest","unreadOnly":true}"#.utf8))
    #expect(old == ThreadListOptions(sort: .oldest, unreadOnly: true))
}

@Test func tagsAreCaseInsensitiveAcrossAccounts() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var gmail = sampleMessage(key: "g", thread: "gmail:1", subject: "G", body: "x")
    gmail.accountID = "gmail"
    gmail.labels = ["Šport", "Práca"]
    var work = sampleMessage(key: "w", thread: "work:1", subject: "W", body: "y")
    work.accountID = "work"
    work.labels = ["šport"]
    var other = sampleMessage(key: "o", thread: "work:2", subject: "O", body: "z")
    other.accountID = "work"
    other.labels = ["Šport", "Praca"]
    try await index.upsert(gmail)
    try await index.upsert(work)
    try await index.upsert(other)

    // One "Šport" (most used spelling), "Práca" and "Praca" stay separate.
    #expect(try await index.allTags() == ["Praca", "Práca", "Šport"])
    #expect(try await index.tagCounts()["šport"] == 3)
    #expect(Set(try await index.threads(filter: .tag("ŠPORT")).map(\.id)) == ["gmail:1", "work:1", "work:2"])
    #expect(try await index.threads(filter: .all).first { $0.id == "gmail:1" }?.tags == ["Šport", "Práca"])
}

@Test func snoozedThreadsLeaveTheInboxUntilDue() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var labeled = sampleMessage(key: "a", thread: "t1", subject: "Neskôr", body: "x")
    labeled.labels = ["Odložené", "Práca"]
    try await index.upsert(labeled)
    try await index.upsert(sampleMessage(key: "b", thread: "t2", subject: "Teraz", body: "y"))
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 1, key: "a")
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 2, key: "b")

    let wake = Date().addingTimeInterval(3600)
    try await index.setSnooze(threadID: "t1", account: "acc", until: wake)
    #expect(try await index.threads(filter: .inbox).map(\.id) == ["t2"])
    #expect(try await index.threads(filter: .snoozed).map(\.id) == ["t1"])
    #expect(try await index.dueSnoozes().isEmpty)
    #expect(try await index.dueSnoozes(at: wake.addingTimeInterval(1)).map(\.threadID) == ["t1"])
    #expect(try await index.threads(filter: .snoozed).first?.tags == ["Práca"])

    try await index.removeSnooze(threadID: "t1")
    #expect(Set(try await index.threads(filter: .inbox).map(\.id)) == ["t1", "t2"])
}

@Test func scheduledDraftKeepsItsTime() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DraftStore(vault: MailVault(root: dir))
    let when = ISO8601DateFormatter().date(from: "2026-10-15T06:00:00Z")!
    try store.save(SavedDraft(accountID: "acc", to: "a@b.sk", subject: "Ráno", body: "Ahoj", scheduledAt: when))
    #expect(store.all().first?.scheduledAt == when)
    try store.save(SavedDraft(accountID: "acc", subject: "Bez plánu", body: "x"))
    #expect(store.all().filter { $0.scheduledAt == nil }.count == 1)
}

@Test func addressSuggestionsPreferPeopleYouWriteTo() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var fromJan = sampleMessage(key: "a", thread: "t1", subject: "A", body: "x")
    fromJan.from = EmailAddress(name: "Ján Novák", address: "jan@example.sk")
    fromJan.to = [EmailAddress(name: "Peter", address: "me@example.com")]
    var toEva = sampleMessage(key: "b", thread: "t2", subject: "B", body: "y")
    toEva.from = EmailAddress(name: "Peter", address: "Me@example.com")
    toEva.to = [EmailAddress(name: "Eva Šepková", address: "eva@firma.sk")]
    toEva.cc = [EmailAddress(name: nil, address: "jan@example.sk")]
    var news = sampleMessage(key: "c", thread: "t3", subject: "C", body: "z")
    news.from = EmailAddress(name: "Novinky", address: "noreply@shop.sk")
    for m in [fromJan, toEva, news] { try await index.upsert(m) }
    try await index.upsert({ var m = news; m.key = "d"; return m }())

    let suggestions = try await index.addressSuggestions(ownAddresses: ["me@example.com"])
    #expect(!suggestions.contains { $0.address == "me@example.com" })
    let jan = try #require(suggestions.first { $0.address == "jan@example.sk" })
    #expect(jan.name == "Ján Novák" && jan.seen == 2 && jan.sent == 1)
    #expect(suggestions.first { $0.address == "eva@firma.sk" }?.sent == 1)
    #expect(suggestions.last?.address == "noreply@shop.sk")
}

@Test func signatureDelimiterStaysPlainText() {
    let html = MarkdownRenderer.html(from: "Ahoj\n\n-- \nJán Novák\n**Firma** s.r.o.\n\n> citát")
    #expect(!html.contains("<h2>"))
    #expect(!html.contains("<ul>"))
    #expect(!html.contains("<hr"))
    #expect(html.contains("Ján Novák<br"))
    #expect(html.contains("<strong>Firma</strong>"))
}

@Test func inlineImagesBecomeDataURLs() {
    let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    let raw = """
    From: a@b.sk\r
    Subject: logo\r
    MIME-Version: 1.0\r
    Content-Type: multipart/related; boundary="X"\r
    \r
    --X\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <p>Ahoj</p><img src="cid:logo@firma"><img src="https://tracker.example/p.gif">\r
    --X\r
    Content-Type: image/png; name="logo.png"\r
    Content-ID: <logo@firma>\r
    Content-Transfer-Encoding: base64\r
    \r
    \(png)\r
    --X--\r

    """
    let display = MIMEMessage(data: Data(raw.utf8)).displayHTML
    #expect(display?.html.contains("data:image/png;base64,\(png)") == true)
    #expect(display?.html.contains("cid:") == false)
    #expect(display?.missingInlineImages == 0)
    #expect(display?.hasRemoteImages == true)
    #expect(MIMEMessage.hasRemoteImages("<p>bez obrázkov</p><img src=\"data:image/png;base64,AA\">") == false)
}

@Test func trackingPixelsAreRemoved() {
    let html = """
    <img src="https://cdn.example.com/hero.jpg" width="600" height="300">
    <img src="https://t.example.com/x.gif" width="1" height="1" alt="">
    <img src='https://mail.example.com/abc' style="width:1px;height:1px;border:0">
    <img src="https://u123.list-manage.com/track/open.php?u=1">
    <img src="https://cdn.example.com/logo.png" style="display: none">
    <img src="data:image/png;base64,AA" width="1" height="1">
    <img src="https://cdn.example.com/icon.png" width="16">
    """
    let (cleaned, removed) = TrackerFilter.strip(html)
    #expect(removed == 4)
    #expect(cleaned.contains("hero.jpg"))
    #expect(cleaned.contains("icon.png"))
    #expect(cleaned.contains("data:image/png"))
    #expect(!cleaned.contains("x.gif"))
    #expect(!cleaned.contains("list-manage"))
}

@Test func plainTextOnlyMessage() {
    var draft = Draft(from: EmailAddress(name: nil, address: "a@b.sk"), to: [EmailAddress(name: nil, address: "c@d.sk")],
                      subject: "Ahoj", markdown: "**Tučné** a [odkaz](https://x.sk)")
    draft.plainTextOnly = true
    let message = MIMEMessage(data: MessageBuilder.build(draft).data)
    #expect(message.root.mimeType == "text/plain")
    #expect(message.html == nil)
    #expect(message.plainText?.contains("Tučné") == true)
    #expect(message.plainText?.contains("**") == false)

    draft.attachments = [OutgoingAttachment(filename: "a.txt", data: Data("x".utf8))]
    let mixed = MIMEMessage(data: MessageBuilder.build(draft).data)
    #expect(mixed.html == nil)
    #expect(mixed.attachments.count == 1)
    #expect(mixed.plainText?.contains("Tučné") == true)
}

@Test func integrityCheckReportsOK() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "mm-integrity-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let index = try MailIndex(url: url)
    #expect(try await index.integrityCheck() == "ok")
    #expect(try await index.messageCounts().isEmpty)
}

@Test func rulesMatchConditions() {
    var message = sampleMessage(key: "r1", thread: "t", subject: "Faktúra č. 2026/15", body: "Dobrý deň, v prílohe posielame faktúru.")
    message.from = EmailAddress(name: "Notifikácie Banky", address: "notifikacie@banka.sk")
    message.attachments = ["faktura.pdf"]
    let context = RuleContext(message: message, isNewsletter: false, attachmentBytes: 12_000_000)

    let invoices = MailRule(name: "Faktúry", conditions: [RuleCondition(field: .subject, value: "invoice, FAKTURA")], actions: [.star])
    #expect(RuleEngine.matches(invoices, context))

    let bank = MailRule(name: "Banka", conditions: [RuleCondition(field: .sender, op: .endsWith, value: "@banka.sk")], actions: [.markRead])
    #expect(RuleEngine.matches(bank, context))

    let big = MailRule(name: "Veľké", conditions: [RuleCondition(field: .attachmentSize, op: .greaterThan, value: "10")], actions: [.tag("Veľké prílohy")])
    #expect(RuleEngine.matches(big, context))
    #expect(!RuleEngine.matches(big, RuleContext(message: message, isNewsletter: false, attachmentBytes: 2_000_000)))

    let all = MailRule(name: "Obe", matchAll: true,
                       conditions: [RuleCondition(field: .subject, value: "faktura"), RuleCondition(field: .newsletter)], actions: [.archive])
    #expect(!RuleEngine.matches(all, context))
    var any = all
    any.matchAll = false
    #expect(RuleEngine.matches(any, context))

    let notFrom = MailRule(name: "Nie banka", conditions: [RuleCondition(field: .sender, op: .notContains, value: "banka")], actions: [.star])
    #expect(!RuleEngine.matches(notFrom, context))

    var otherAccount = invoices
    otherAccount.accountID = "iné"
    #expect(!RuleEngine.matches(otherAccount, context))

    // Empty text conditions never match everything by accident.
    let empty = MailRule(name: "Prázdne", conditions: [RuleCondition(field: .subject, value: " ")], actions: [.trash])
    #expect(!RuleEngine.matches(empty, context))
}

@Test func rulesRoundTripThroughJSON() throws {
    let rule = MailRule(name: "Klienti", conditions: [RuleCondition(field: .sender, value: "@klient.sk")],
                        actions: [.moveToFolder("INBOX.Klienti"), .tag("Klient"), .noNotification], afterDays: 7)
    let decoded = try JSONDecoder().decode(MailRule.self, from: JSONEncoder().encode(rule))
    #expect(decoded == rule)
}

@Test func inboxRowShowsTheirMessageNotMyReply() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))

    var theirs = sampleMessage(key: "q", thread: "t", subject: "Otázka", body: "Dobrý deň, mám otázku")
    theirs.date = Date(timeIntervalSince1970: 1_000)
    var mine = sampleMessage(key: "r", thread: "t", subject: "Re: Otázka", body: "Odpoveď od mňa", seen: true)
    mine.from = EmailAddress(name: "Ja", address: "ja@example.sk")
    mine.date = Date(timeIntervalSince1970: 2_000)
    var other = sampleMessage(key: "o", thread: "u", subject: "Iné", body: "iné vlákno")
    other.date = Date(timeIntervalSince1970: 1_500)
    for message in [theirs, mine, other] { try await index.upsert(message) }
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 1, key: "q")
    try await index.addMembership(account: "acc", mailbox: "INBOX", role: .inbox, uid: 2, key: "o")
    try await index.addMembership(account: "acc", mailbox: "Sent", role: .sent, uid: 1, key: "r")

    let inbox = try await index.threads(filter: .inbox)
    // My reply does not move the thread above newer mail, and the row shows their message.
    #expect(inbox.map(\.id) == ["u", "t"])
    let row = try #require(inbox.last)
    #expect(row.snippet == "Dobrý deň, mám otázku")
    #expect(row.latestSender == "Ján Novák")
    #expect(row.date == Date(timeIntervalSince1970: 1_000))
    #expect(row.messageCount == 2)
    #expect(row.hasLaterMessage)
    #expect(row.lastAction == .replied)
    #expect(inbox.first?.lastAction == nil)

    // In Sent the same thread shows my reply.
    let sent = try await index.threads(filter: .sent)
    #expect(sent.first?.snippet == "Odpoveď od mňa")
    #expect(sent.first?.hasLaterMessage == false)
}

@Test func mailboxSnapshotsRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    let snapshot = MailboxSnapshot(uidValidity: 7, uidNext: 152_200, count: 31_417, modSeq: 9_876_543_210)
    #expect(try await index.mailboxSnapshot(account: "acc", mailbox: "INBOX") == nil)
    try await index.setMailboxSnapshot(snapshot, account: "acc", mailbox: "INBOX")
    #expect(try await index.mailboxSnapshot(account: "acc", mailbox: "INBOX") == snapshot)
    try await index.clearMailboxSnapshots(account: "acc")
    #expect(try await index.mailboxSnapshot(account: "acc", mailbox: "INBOX") == nil)
}

@Test func followUpsDetectAnswers() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var mine = sampleMessage(key: "m", thread: "t", subject: "Ponuka", body: "Posielam ponuku", seen: true)
    mine.from = EmailAddress(name: "Ja", address: "ja@example.sk")
    mine.date = Date(timeIntervalSince1970: 1_000)
    try await index.upsert(mine)
    try await index.addMembership(account: "acc", mailbox: "Sent", role: .sent, uid: 1, key: "m")
    try await index.setFollowUp(threadID: "t", account: "acc", due: Date(timeIntervalSince1970: 5_000),
                                since: Date(timeIntervalSince1970: 1_000))

    #expect(try await index.threads(filter: .followUps).map(\.id) == ["t"])
    #expect(try await index.hasReply(threadID: "t", after: mine.date, ownAddresses: ["ja@example.sk"]) == false)

    // My own second message does not count as their answer.
    var again = mine
    again.key = "m2"
    again.date = Date(timeIntervalSince1970: 2_000)
    try await index.upsert(again)
    #expect(try await index.hasReply(threadID: "t", after: mine.date, ownAddresses: ["JA@example.sk"]) == false)

    var answer = sampleMessage(key: "a", thread: "t", subject: "Re: Ponuka", body: "Ďakujem, beriem")
    answer.date = Date(timeIntervalSince1970: 3_000)
    try await index.upsert(answer)
    #expect(try await index.hasReply(threadID: "t", after: mine.date, ownAddresses: ["ja@example.sk"]))

    try await index.markFollowUpFired(threadID: "t")
    #expect(try await index.followUps()["t"]?.fired == true)
    try await index.removeFollowUp(threadID: "t")
    #expect(try await index.followUps().isEmpty)
}

@Test func searchQueryParsesOperators() {
    let query = SearchQuery("from:dodavatel has:attachment is:unread after:2026-09 \"cenová ponuka\" before:15.10.2026 10:30")
    #expect(query.from == ["dodavatel"])
    #expect(query.hasAttachment)
    #expect(query.unread == true)
    #expect(query.text == ["cenová ponuka", "10:30"])
    let calendar = Calendar(identifier: .gregorian)
    #expect(query.after.map { calendar.component(.month, from: $0) } == 9)
    #expect(query.before.map { calendar.component(.day, from: $0) } == 15)

    let slovak = SearchQuery("od:Šepková má:prílohu je:neprečítané predmet:faktúra")
    #expect(slovak.from == ["Šepková"])
    #expect(slovak.hasAttachment)
    #expect(slovak.unread == true)
    #expect(slovak.subject == ["faktúra"])
}

@Test func searchOperatorsFilterThreads() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var invoice = sampleMessage(key: "i", thread: "t1", subject: "Faktúra september", body: "v prílohe")
    invoice.from = EmailAddress(name: "Dodávateľ s.r.o.", address: "faktury@dodavatel.sk")
    invoice.attachments = ["faktura.pdf"]
    invoice.date = Date(timeIntervalSince1970: 1_790_000_000)
    var lunch = sampleMessage(key: "l", thread: "t2", subject: "Obed", body: "ideme?", seen: true)
    lunch.date = Date(timeIntervalSince1970: 1_700_000_000)
    for message in [invoice, lunch] { try await index.upsert(message) }

    #expect(try await index.threads(filter: .all, search: "od:dodavatel").map(\.id) == ["t1"])
    #expect(try await index.threads(filter: .all, search: "from:Ján has:attachment").map(\.id) == [])
    #expect(try await index.threads(filter: .all, search: "has:attachment").map(\.id) == ["t1"])
    #expect(try await index.threads(filter: .all, search: "is:read").map(\.id) == ["t2"])
    #expect(try await index.threads(filter: .all, search: "after:2026-01").map(\.id) == ["t1"])
    let bySubject = try await index.threads(filter: .all, search: "predmet:faktura").map(\.id)
    let byText = try await index.threads(filter: .all, search: "prilohe").map(\.id)
    #expect(bySubject == ["t1"])
    #expect(byText == ["t1"])
    #expect(try await index.threads(filter: .all, search: "predmet:faktura prilohe").map(\.id) == ["t1"])
}

@Test func unsubscribeHeaderPrefersOneClick() {
    let raw = """
    From: news@shop.sk\r
    Subject: Akcia\r
    List-Unsubscribe: <mailto:leave@shop.sk?subject=Odhl%C3%A1si%C5%A5&body=bye>,\r
     <https://shop.sk/u/abc123>\r
    List-Unsubscribe-Post: List-Unsubscribe=One-Click\r
    Content-Type: text/plain\r
    \r
    Zľavy!\r

    """
    let info = MIMEMessage(data: Data(raw.utf8)).unsubscribe
    #expect(info?.web == URL(string: "https://shop.sk/u/abc123"))
    #expect(info?.mailto?.address == "leave@shop.sk")
    #expect(info?.mailto?.subject == "Odhlásiť")
    #expect(info?.preferred == .oneClick(URL(string: "https://shop.sk/u/abc123")!))

    let mailOnly = MIMEMessage(data: Data("From: a@b.sk\r\nList-Unsubscribe: <mailto:off@b.sk>\r\n\r\nx".utf8)).unsubscribe
    #expect(mailOnly?.preferred == .email(address: "off@b.sk", subject: "unsubscribe", body: ""))

    let webOnly = MIMEMessage(data: Data("From: a@b.sk\r\nList-Unsubscribe: <https://b.sk/out>\r\n\r\nx".utf8)).unsubscribe
    #expect(webOnly?.preferred == .website(URL(string: "https://b.sk/out")!))

    #expect(MIMEMessage(data: Data("From: a@b.sk\r\n\r\nx".utf8)).unsubscribe == nil)
    #expect(UnsubscribeInfo.oneClickRequest(URL(string: "https://shop.sk/u/abc123")!).httpMethod == "POST")
}

@Test func draftsRoundTripThroughTheServerFormat() throws {
    var draft = SavedDraft(accountID: "acc", to: "\"Ján Novák\" <jan@example.sk>", cc: "eva@example.sk",
                           subject: "Ponuka", body: "Dobrý deň,\n\nposielam **ponuku**.",
                           inReplyTo: "abc@x", references: ["abc@x"],
                           attachments: [OutgoingAttachment(filename: "ponuka.pdf", data: Data("%PDF".utf8))])
    let (data, messageID) = draft.mimeMessage(from: EmailAddress(name: "Ja", address: "ja@firma.sk"))
    #expect(messageID == "draft-\(draft.id.uuidString.lowercased())@firma.sk")

    let back = SavedDraft(serverDraft: data, accountID: "acc")
    #expect(back.serverMessageID == messageID)
    #expect(back.to.contains("jan@example.sk"))
    #expect(back.cc == "eva@example.sk")
    #expect(back.subject == "Ponuka")
    #expect(back.body.contains("posielam ponuku."))
    #expect(back.inReplyTo == "abc@x")
    #expect(back.attachments.map(\.filename) == ["ponuka.pdf"])

    // A second version keeps the same Message-ID, so the server copy is replaced, not duplicated.
    draft.serverMessageID = messageID
    draft.body += "\nDoplnené."
    #expect(draft.mimeMessage(from: EmailAddress(name: nil, address: "ja@firma.sk")).messageID == messageID)

    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DraftStore(vault: MailVault(root: dir))
    draft.serverSynced = Date(timeIntervalSince1970: 1_800_000_000)
    try store.save(draft)
    let loaded = try #require(store.all().first)
    #expect(loaded.serverMessageID == messageID)
    #expect(loaded.serverSynced == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func calendarInvitesParseAndReply() throws {
    let raw = """
    From: Eva <organizer@example.com>\r
    Subject: Pozvánka: Kick off meeting\r
    MIME-Version: 1.0\r
    Content-Type: multipart/alternative; boundary="B"\r
    \r
    --B\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Pozvánka\r
    --B\r
    Content-Type: text/calendar; charset="UTF-8"; method=REQUEST\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VTIMEZONE\r
    TZID:Europe/Prague\r
    BEGIN:DAYLIGHT\r
    DTSTART:19700329T020000\r
    END:DAYLIGHT\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    DTSTART;TZID=3DEurope/Prague:20260922T150000\r
    DTEND;TZID=3DEurope/Prague:20260922T160000\r
    ORGANIZER;CN=3DEva:mailto:organizer@example.com\r
    UID:a1b2c3d4e5f6g7h8i9j0k1l2m3@google.com\r
    ATTENDEE;PARTSTAT=3DACCEPTED:mailto:organizer@example.com\r
    ATTENDEE;CUTYPE=3DINDIVIDUAL;PARTSTAT=3DNEEDS-ACTION;RSVP=3D\r
     TRUE;CN=3Djan.novak@example.com:mailto:jan.no=\r
    vak@ex\r
     ample.com\r
    X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r
    SUMMARY:Kick off meeting\\, projekt\r
    LOCATION:Bratislava\r
    BEGIN:VALARM\r
    ACTION:DISPLAY\r
    DESCRIPTION:This is an event reminder\r
    END:VALARM\r
    SEQUENCE:2\r
    END:VEVENT\r
    END:VCALENDAR\r
    --B--\r

    """
    let invite = try #require(MIMEMessage(data: Data(raw.utf8)).invite)
    #expect(invite.method == .request)
    #expect(invite.summary == "Kick off meeting, projekt")
    #expect(invite.sequence == 2)
    #expect(invite.location == "Bratislava")
    #expect(invite.details == nil) // the alarm's DESCRIPTION is not the event's
    #expect(invite.organizer?.address == "organizer@example.com")
    #expect(invite.status(of: ["Jan.Novak@Example.com"]) == .needsAction)
    #expect(invite.conferenceURL == URL(string: "https://meet.google.com/abc-defg-hij"))
    // 15:00 in Prague (summer time, UTC+2) is 13:00 UTC.
    #expect(invite.start == ISO8601DateFormatter().date(from: "2026-09-22T13:00:00Z"))
    #expect(invite.end == ISO8601DateFormatter().date(from: "2026-09-22T14:00:00Z"))

    let reply = invite.reply(.accepted, from: EmailAddress(name: "Ján", address: "jan.novak@example.com"))
    #expect(reply.contains("METHOD:REPLY"))
    #expect(reply.contains("UID:a1b2c3d4e5f6g7h8i9j0k1l2m3@google.com"))
    #expect(reply.contains("SEQUENCE:2"))
    #expect(reply.contains("PARTSTAT=ACCEPTED"))
    #expect(reply.contains("DTSTART:20260922T130000Z"))

    var draft = Draft(from: EmailAddress(name: nil, address: "jan.novak@example.com"),
                      to: [EmailAddress(name: nil, address: "organizer@example.com")], subject: "Prijaté: Kick off", markdown: "Prijaté")
    draft.calendarReply = reply
    let sent = MIMEMessage(data: MessageBuilder.build(draft).data)
    #expect(sent.invite?.method == .reply)
}

@Test func allDayInvites() throws {
    let invite = try #require(CalendarInvite(ics: "BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:x\nDTSTART;VALUE=DATE:20261020\nDTEND;VALUE=DATE:20261021\nSUMMARY:Dovolenka\nEND:VEVENT\nEND:VCALENDAR"))
    #expect(invite.isAllDay)
    #expect(invite.isCancelled)
    #expect(Calendar.current.component(.day, from: invite.start!) == 20)
}

@Test func summariesAreKeptPerThread() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    #expect(try await index.summary(threadID: "t") == nil)
    try await index.setSummary("- O čom je vlákno", threadID: "t", latestKey: "k2", created: Date(timeIntervalSince1970: 1_000))
    let stored = try #require(try await index.summary(threadID: "t"))
    #expect(stored.text == "- O čom je vlákno")
    #expect(stored.latestKey == "k2")
    try await index.removeSummary(threadID: "t")
    #expect(try await index.summary(threadID: "t") == nil)
}

@Test func personStatsAndWithOperator() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    var theirs = sampleMessage(key: "a", thread: "t1", subject: "Ponuka", body: "x")
    theirs.from = EmailAddress(name: "Ján", address: "jan@firma.sk")
    theirs.date = Date(timeIntervalSince1970: 1_000)
    var mine = sampleMessage(key: "b", thread: "t1", subject: "Re: Ponuka", body: "y")
    mine.from = EmailAddress(name: "Ja", address: "ja@x.sk")
    mine.to = [EmailAddress(name: "Ján", address: "Jan@Firma.sk")]
    mine.date = Date(timeIntervalSince1970: 2_000)
    var other = sampleMessage(key: "c", thread: "t2", subject: "Iné", body: "z")
    other.from = EmailAddress(name: "Eva", address: "eva@iny.sk")
    for message in [theirs, mine, other] { try await index.upsert(message) }

    let stats = try await index.personStats(address: "jan@firma.sk", ownAddresses: ["ja@x.sk"])
    #expect(stats.messages == 2)
    #expect(stats.threads == 1)
    #expect(stats.lastFromThem == Date(timeIntervalSince1970: 1_000))
    #expect(stats.lastToThem == Date(timeIntervalSince1970: 2_000))
    #expect(try await index.threads(filter: .all, search: "s:jan@firma.sk").map(\.id) == ["t1"])
}

@Test func eventsFromInvitationsAreIndexed() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "mailmule-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = try MailIndex(url: dir.appending(path: "index.sqlite"))
    let message = sampleMessage(key: "m", thread: "t", subject: "Pozvánka", body: "")
    let invite = try #require(CalendarInvite(ics: "BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:u1\nDTSTART:20261015T080000Z\nDTEND:20261015T090000Z\nSUMMARY:Porada\nLOCATION:Kancelária\nEND:VEVENT\nEND:VCALENDAR"))
    try await index.upsertEvent(invite, message: message)
    let day = Calendar(identifier: .gregorian)
    var utc = day
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    let events = try await index.events(from: start, to: start.addingTimeInterval(86_400))
    #expect(events.map(\.summary) == ["Porada"])
    #expect(events.first?.location == "Kancelária")
    #expect(events.first?.threadID == "t")
    #expect(try await index.events(from: start.addingTimeInterval(86_400), to: start.addingTimeInterval(2 * 86_400)).isEmpty)
}
