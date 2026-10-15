import Foundation
import Testing
@testable import MailmuleKit

struct OutboxTests {
    @Test func retryableErrors() {
        #expect(SMTPClient.isRetryable(ConnectionError.timeout))
        #expect(SMTPClient.isRetryable(ConnectionError.failed("offline")))
        #expect(SMTPClient.isRetryable(URLError(.notConnectedToInternet)))
        #expect(SMTPClient.isRetryable(SMTPError.unexpectedReply(stage: "RCPT TO", reply: "451 try again later")))
        #expect(!SMTPClient.isRetryable(SMTPError.unexpectedReply(stage: "prihlásenie", reply: "535 bad credentials")))
        #expect(!SMTPClient.isRetryable(SMTPError.uncertain("closed")))
    }

    @Test func outboxSurvivesSaving() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mm-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(vault: MailVault(root: root))
        var draft = SavedDraft(accountID: "a", to: "x@y.sk", subject: "Ahoj", body: "text", scheduledAt: Date())
        draft.outbox = true
        draft.sendAttempts = 3
        draft.sendError = "Server neodpovedal včas."
        try store.save(draft)
        let loaded = try #require(store.all().first)
        #expect(loaded.outbox)
        #expect(loaded.sendAttempts == 3)
        #expect(loaded.sendError == "Server neodpovedal včas.")
    }

    @Test func oldAccountsGetSecurityFromPort() throws {
        let json = #"{"id":"a","name":"A","email":"a@b.sk","username":"a@b.sk","imapHost":"h","imapPort":143,"smtpHost":"s","smtpPort":587}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.imapSecurity == .startTLS)
        #expect(account.smtpSecurity == .startTLS)
        let tls = Account(name: "A", email: "a@b.sk", imapHost: "h", smtpHost: "s")
        #expect(tls.imapSecurity == .tls && tls.smtpSecurity == .tls)
    }
}

struct DamagedIndexTests {
    /// AppModel.openIndex recognises a damaged file by this text and creates a new index.
    @Test func garbageFileIsReportedAsNotADatabase() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mm-broken-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x42, count: 8192).write(to: url)
        do {
            _ = try MailIndex(url: url)
            Issue.record("expected an error")
        } catch {
            let text = "\(error)".lowercased()
            #expect(text.contains("not a database") || text.contains("malformed") || text.contains("corrupt"), "\(error)")
        }
    }
}
