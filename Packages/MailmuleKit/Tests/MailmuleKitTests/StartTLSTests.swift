import Foundation
import Testing
@testable import MailmuleKit

/// Live STARTTLS handshakes (no login). Run with MM_NET_TESTS=1; the IMAP server comes from
/// MM_STARTTLS_IMAP (Gmail offers no STARTTLS on 143).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MM_NET_TESTS"] == "1"))
struct StartTLSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_STARTTLS_IMAP"] != nil),
          arguments: [ProcessInfo.processInfo.environment["MM_STARTTLS_IMAP"] ?? ""])
    func imapStartTLS(host: String) async throws {
        let connection = LineConnection(host: host, port: 143, security: .startTLS)
        try await connection.open()
        let greeting = String(decoding: try await connection.readLine(), as: UTF8.self)
        #expect(greeting.hasPrefix("* OK"))
        try await connection.send("a STARTTLS\r\n")
        let ok = String(decoding: try await connection.readLine(), as: UTF8.self)
        #expect(ok.hasPrefix("a OK"))
        await connection.startTLS()
        try await connection.send("b CAPABILITY\r\n")
        var lines: [String] = []
        while true {
            let line = String(decoding: try await connection.readLine(), as: UTF8.self)
            lines.append(line)
            if line.hasPrefix("b ") { break }
        }
        #expect(lines.last?.hasPrefix("b OK") == true)
        #expect(lines.contains { $0.contains("AUTH=PLAIN") || $0.contains("IMAP4") })
        await connection.close()
    }

    @Test(arguments: ["smtp.gmail.com", "smtp.mail.me.com"])
    func smtpStartTLS(host: String) async throws {
        let connection = LineConnection(host: host, port: 587, security: .startTLS)
        try await connection.open()
        func reply() async throws -> String {
            var text = ""
            while true {
                let line = String(decoding: try await connection.readLine(), as: UTF8.self)
                text += line
                if line.count < 4 || Array(line)[3] != "-" { return text }
            }
        }
        #expect(try await reply().hasPrefix("220"))
        try await connection.send("EHLO mailmule.local\r\n")
        #expect(try await reply().contains("STARTTLS"))
        try await connection.send("STARTTLS\r\n")
        #expect(try await reply().hasPrefix("220"))
        await connection.startTLS()
        try await connection.send("EHLO mailmule.local\r\n")
        let ehlo = try await reply()
        #expect(ehlo.hasPrefix("250"))
        #expect(ehlo.contains("AUTH"))
        await connection.close()
    }
}
