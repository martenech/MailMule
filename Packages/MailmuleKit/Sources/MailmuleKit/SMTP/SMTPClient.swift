import Foundation

public enum SMTPError: Error, LocalizedError {
    case unexpectedReply(stage: String, reply: String)
    /// The connection broke after the message was handed over: it may or may not have gone out.
    case uncertain(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedReply(let stage, let reply): "SMTP \(stage) zlyhal: \(reply)"
        case .uncertain(let reason): "Spojenie sa prerušilo počas odosielania (\(reason)); správa možno odišla – skontrolujte Odoslané."
        }
    }
}

/// SMTP submission over implicit TLS (port 465) or STARTTLS (587), authenticated with AUTH PLAIN.
public struct SMTPClient: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String
    public let security: ConnectionSecurity

    public init(host: String, port: UInt16, username: String, password: String, security: ConnectionSecurity = .tls) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
    }

    public func send(_ message: Data, from: String, to recipients: [String]) async throws {
        let connection = LineConnection(host: host, port: port, security: security)
        try await connection.open()
        do {
            try await converse(connection, message: message, from: from, to: recipients)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    private func converse(_ connection: LineConnection, message: Data, from: String, to recipients: [String]) async throws {
        try await expect(connection, 220, stage: "pozdrav")
        try await connection.send("EHLO mailmule.local\r\n")
        try await expect(connection, 250, stage: "EHLO")
        if security == .startTLS {
            try await connection.send("STARTTLS\r\n")
            try await expect(connection, 220, stage: "STARTTLS")
            await connection.startTLS()
            try await connection.send("EHLO mailmule.local\r\n")
            try await expect(connection, 250, stage: "EHLO")
        }

        let credentials = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        try await connection.send("AUTH PLAIN \(credentials)\r\n")
        try await expect(connection, 235, stage: "prihlásenie")

        try await connection.send("MAIL FROM:<\(from)>\r\n")
        try await expect(connection, 250, stage: "MAIL FROM")
        for recipient in recipients {
            try await connection.send("RCPT TO:<\(recipient)>\r\n")
            try await expect(connection, 250, stage: "RCPT TO \(recipient)")
        }
        try await connection.send("DATA\r\n")
        try await expect(connection, 354, stage: "DATA")
        try await connection.send(Self.dotStuffed(message))
        do {
            try await expect(connection, 250, stage: "odoslanie")
        } catch let error as ConnectionError {
            throw SMTPError.uncertain(error.localizedDescription)
        }
        try? await connection.send("QUIT\r\n")
    }

    /// Whether sending can simply be tried again later: the network failed before the message was handed
    /// over, or the server answered with a temporary 4xx code. Rejections (5xx) and uncertain sends are not.
    public static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is ConnectionError, is URLError:
            return true
        case SMTPError.unexpectedReply(_, let reply):
            return reply.hasPrefix("4")
        default:
            let ns = error as NSError
            return ns.domain == NSPOSIXErrorDomain || ns.domain == "kNWErrorDomainPOSIX" || ns.domain == "kNWErrorDomainDNS"
        }
    }

    /// Reads a (possibly multi-line) reply and checks its code.
    private func expect(_ connection: LineConnection, _ code: Int, stage: String) async throws {
        var reply = ""
        while true {
            let line = String(decoding: try await connection.readLine(), as: UTF8.self)
            reply += line
            // "250-..." continues, "250 ..." ends.
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        guard Int(reply.prefix(3)) == code else {
            throw SMTPError.unexpectedReply(stage: stage, reply: reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Escapes lines starting with "." and appends the end-of-data marker.
    static func dotStuffed(_ message: Data) -> Data {
        var text = String(decoding: message, as: UTF8.self)
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        return Data((text + ".\r\n").utf8)
    }
}
