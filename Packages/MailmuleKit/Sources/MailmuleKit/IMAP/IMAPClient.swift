import Foundation

public enum IMAPError: Error, LocalizedError {
    case commandFailed(command: String, status: String, text: String)
    case unexpectedGreeting(String)
    case missingMailbox(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let status, let text): "IMAP \(command) zlyhal (\(status)): \(text)"
        case .unexpectedGreeting(let text): "Neočakávaná odpoveď servera: \(text)"
        case .missingMailbox(let role): "Na serveri som nenašiel priečinok: \(role)"
        }
    }
}

public struct IMAPMailbox: Sendable, Hashable {
    public let name: String
    public let attributes: Set<String>
    public var delimiter: String? = nil

    /// Last path component, e.g. `Sent` for `INBOX.Sent`.
    public var leafName: String {
        guard let delimiter, !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }

    public func has(_ attribute: String) -> Bool {
        attributes.contains(attribute.lowercased())
    }
}

public struct IMAPSelectInfo: Sendable {
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32 = 0
    public var exists: UInt32 = 0
    /// CONDSTORE HIGHESTMODSEQ (0 without CONDSTORE).
    public var highestModSeq: UInt64 = 0
}

public struct IMAPFetchResult: Sendable {
    public let uid: UInt32
    public let attributes: [String: IMAPValue]

    public var flags: [String] {
        attributes["FLAGS"]?.list?.compactMap(\.text) ?? []
    }

    public var gmailLabels: [String] {
        attributes["X-GM-LABELS"]?.list?.compactMap(\.text) ?? []
    }

    public var gmailThreadID: String? {
        attributes["X-GM-THRID"]?.text
    }

    /// Value of the first `BODY[...]` section in the response.
    public func body(_ section: String = "") -> Data? {
        if section.isEmpty { return attributes["BODY[]"]?.data }
        return attributes.first { $0.key.hasPrefix("BODY[\(section.uppercased())") }?.value.data
    }
}

/// Minimal IMAP4rev1 client with the Gmail extensions Mailmule needs.
public actor IMAPClient {
    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let security: ConnectionSecurity

    private var connection: LineConnection?
    private var tagCounter = 0
    private var idleDoneSent = true
    private var selected: String?
    public private(set) var capabilities: Set<String> = []

    public init(host: String, port: UInt16, username: String, password: String, security: ConnectionSecurity = .tls) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
    }

    public var isGmail: Bool { capabilities.contains("X-GM-EXT-1") }
    public var isConnected: Bool { connection != nil }

    public func connect() async throws {
        let connection = LineConnection(host: host, port: port, security: security)
        try await connection.open()
        self.connection = connection
        selected = nil

        let greeting = try IMAPParser.parse(try await readResponse())
        guard case .status(nil, let kind, _, _) = greeting, kind == "OK" || kind == "PREAUTH" else {
            await disconnect()
            throw IMAPError.unexpectedGreeting("\(greeting)")
        }
        if security == .startTLS {
            // Never send the password unencrypted: if the server refuses STARTTLS, give up.
            do {
                _ = try await execute("STARTTLS")
            } catch {
                await disconnect()
                throw ConnectionError.failed("server neponúka šifrovanie STARTTLS")
            }
            await connection.startTLS()
        }
        if kind == "OK" {
            do {
                _ = try await execute("LOGIN \(quote(username)) \(quote(password))", logAs: "LOGIN")
            } catch {
                await disconnect()
                throw error
            }
        }
        try await refreshCapabilities()
    }

    public func disconnect() async {
        if let connection {
            try? await connection.send("Z LOGOUT\r\n")
            await connection.close()
        }
        connection = nil
        selected = nil
    }

    private func refreshCapabilities() async throws {
        let responses = try await execute("CAPABILITY")
        for case .data("CAPABILITY", let values) in responses {
            capabilities = Set(values.compactMap { $0.text?.uppercased() })
        }
    }

    public func listMailboxes() async throws -> [IMAPMailbox] {
        let responses = try await execute("LIST \"\" \"*\"")
        return responses.compactMap { response in
            guard case .data("LIST", let values) = response, values.count >= 3,
                  let attrs = values[0].list, let name = values[2].text else { return nil }
            return IMAPMailbox(name: name, attributes: Set(attrs.compactMap { $0.text?.lowercased() }), delimiter: values[1].text)
        }
    }

    @discardableResult
    public func select(_ mailbox: String) async throws -> IMAPSelectInfo {
        // CONDSTORE makes the server report HIGHESTMODSEQ, which tells whether any flag changed.
        let condstore = capabilities.contains("CONDSTORE") ? " (CONDSTORE)" : ""
        let responses = try await execute("SELECT \(quote(mailbox))\(condstore)", logAs: "SELECT")
        selected = mailbox
        var info = IMAPSelectInfo()
        for response in responses {
            switch response {
            case .numbered(let n, "EXISTS", _):
                info.exists = n
            case .status(nil, "OK", let code?, _):
                let parts = code.split(separator: " ")
                if parts.count == 2, let value = UInt32(parts[1]) {
                    if parts[0].uppercased() == "UIDVALIDITY" { info.uidValidity = value }
                    if parts[0].uppercased() == "UIDNEXT" { info.uidNext = value }
                }
                if parts.count == 2, parts[0].uppercased() == "HIGHESTMODSEQ", let value = UInt64(parts[1]) {
                    info.highestModSeq = value
                }
            default:
                break
            }
        }
        return info
    }

    private func ensureSelected(_ mailbox: String) async throws {
        if selected != mailbox { try await select(mailbox) }
    }

    public func uidSearch(in mailbox: String, _ criteria: String = "ALL") async throws -> [UInt32] {
        try await ensureSelected(mailbox)
        let responses = try await execute("UID SEARCH \(criteria)")
        var uids: [UInt32] = []
        for case .data("SEARCH", let values) in responses {
            uids += values.compactMap { $0.text.flatMap(UInt32.init) }
        }
        return uids.sorted()
    }

    /// Messages whose flags changed after `modSeq` (CONDSTORE), usually none or a handful.
    public func uidFetchChanged(in mailbox: String, since modSeq: UInt64, items: String) async throws -> [IMAPFetchResult] {
        try await ensureSelected(mailbox)
        let responses = try await execute("UID FETCH 1:* (\(items)) (CHANGEDSINCE \(modSeq))", logAs: "FETCH")
        var results: [IMAPFetchResult] = []
        for case .numbered(_, "FETCH", let values) in responses {
            guard let attrs = values.first?.list?.fetchAttributes(),
                  let uid = attrs["UID"]?.text.flatMap(UInt32.init) else { continue }
            results.append(IMAPFetchResult(uid: uid, attributes: attrs))
        }
        return results
    }

    public func uidFetch(in mailbox: String, uids: [UInt32], items: String) async throws -> [IMAPFetchResult] {
        guard !uids.isEmpty else { return [] }
        try await ensureSelected(mailbox)
        var results: [IMAPFetchResult] = []
        for chunk in uids.chunked(into: 200) {
            let responses = try await execute("UID FETCH \(Self.uidSet(chunk)) (\(items))")
            for case .numbered(_, "FETCH", let values) in responses {
                guard let attrs = values.first?.list?.fetchAttributes(),
                      let uid = attrs["UID"]?.text.flatMap(UInt32.init) else { continue }
                results.append(IMAPFetchResult(uid: uid, attributes: attrs))
            }
        }
        return results
    }

    public func uidStore(in mailbox: String, uids: [UInt32], _ change: String) async throws {
        guard !uids.isEmpty else { return }
        try await ensureSelected(mailbox)
        _ = try await execute("UID STORE \(Self.uidSet(uids)) \(change)")
    }

    public func uidMove(in mailbox: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await ensureSelected(mailbox)
        let set = Self.uidSet(uids)
        if capabilities.contains("MOVE") {
            _ = try await execute("UID MOVE \(set) \(quote(destination))")
        } else {
            _ = try await execute("UID COPY \(set) \(quote(destination))")
            _ = try await execute("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                _ = try await execute("UID EXPUNGE \(set)")
            } else {
                _ = try await execute("EXPUNGE")
            }
        }
    }

    /// Personal namespace prefix and delimiter, e.g. `("INBOX.", ".")` on many Dovecot/Courier servers.
    public func personalNamespace() async throws -> (prefix: String, delimiter: String)? {
        guard capabilities.contains("NAMESPACE") else { return nil }
        let responses = try await execute("NAMESPACE")
        for case .data("NAMESPACE", let values) in responses {
            guard let first = values.first?.list?.first?.list, first.count >= 2,
                  let prefix = first[0].text else { continue }
            return (prefix, first[1].text ?? "")
        }
        return nil
    }

    public func create(_ mailbox: String) async throws {
        _ = try await execute("CREATE \(quote(mailbox))")
        _ = try? await execute("SUBSCRIBE \(quote(mailbox))")
    }

    public func uidCopy(in mailbox: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await ensureSelected(mailbox)
        _ = try await execute("UID COPY \(Self.uidSet(uids)) \(quote(destination))")
    }

    /// Permanently removes messages: flags them \Deleted and expunges.
    public func uidExpunge(in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await ensureSelected(mailbox)
        let set = Self.uidSet(uids)
        _ = try await execute("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") {
            _ = try await execute("UID EXPUNGE \(set)")
        } else {
            _ = try await execute("EXPUNGE")
        }
    }

    public var supportsIdle: Bool { capabilities.contains("IDLE") }

    /// Waits in IMAP IDLE on the selected mailbox until the server reports a change or
    /// `refreshAfter` passes (servers drop idle connections after ~30 minutes).
    /// Returns true when something changed (new, removed or flagged messages).
    public func idle(in mailbox: String, refreshAfter: Duration = .seconds(25 * 60)) async throws -> Bool {
        guard let connection else { throw ConnectionError.closed }
        try await ensureSelected(mailbox)
        let tag = nextTag()
        try await connection.send("\(tag) IDLE\r\n")
        let first = try IMAPParser.parse(try await readResponse())
        guard case .continuation = first else {
            throw IMAPError.commandFailed(command: "IDLE", status: "BAD", text: "\(first)")
        }
        idleDoneSent = false
        let timer = Task { [weak self] in
            try? await Task.sleep(for: refreshAfter)
            guard !Task.isCancelled else { return }
            await self?.endIdle()
        }
        defer { timer.cancel() }

        // The server stays silent until something changes or DONE is sent after `refreshAfter`.
        await connection.setReadTimeout(Double(refreshAfter.components.seconds) + LineConnection.defaultReadTimeout)
        let result: Result<Bool, Error>
        do {
            result = .success(try await readIdleResponses(tag: tag))
        } catch {
            result = .failure(error)
        }
        await connection.setReadTimeout(LineConnection.defaultReadTimeout)
        return try result.get()
    }

    private func readIdleResponses(tag: String) async throws -> Bool {
        var changed = false
        while true {
            let response = try IMAPParser.parse(try await readResponse())
            switch response {
            case .status(let t?, let kind, _, let text) where t == tag:
                guard kind == "OK" else { throw IMAPError.commandFailed(command: "IDLE", status: kind, text: text) }
                return changed
            case .status(nil, "BYE", _, let text):
                self.connection = nil
                throw IMAPError.commandFailed(command: "IDLE", status: "BYE", text: text)
            case .numbered(_, let kind, _) where ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(kind):
                changed = true
                await endIdle()
            default:
                break
            }
        }
    }

    /// Sends DONE once to leave IDLE; the server then answers the IDLE tag.
    func endIdle() async {
        guard !idleDoneSent, let connection else { return }
        idleDoneSent = true
        try? await connection.send("DONE\r\n")
    }

    public func append(to mailbox: String, flags: [String], message: Data) async throws {
        guard let connection else { throw ConnectionError.closed }
        let tag = nextTag()
        let flagList = flags.joined(separator: " ")
        try await connection.send("\(tag) APPEND \(quote(mailbox)) (\(flagList)) {\(message.count)}\r\n")
        let response = try IMAPParser.parse(try await readResponse())
        guard case .continuation = response else {
            throw IMAPError.commandFailed(command: "APPEND", status: "BAD", text: "\(response)")
        }
        try await connection.send(message + Data("\r\n".utf8))
        _ = try await collect(tag: tag, command: "APPEND")
    }

    // MARK: - Plumbing

    private func nextTag() -> String {
        tagCounter += 1
        return "M\(tagCounter)"
    }

    @discardableResult
    private func execute(_ command: String, logAs: String? = nil) async throws -> [IMAPResponse] {
        guard let connection else { throw ConnectionError.closed }
        let tag = nextTag()
        try await connection.send("\(tag) \(command)\r\n")
        let name = logAs ?? String(command.prefix { $0 != " " })
        return try await collect(tag: tag, command: name)
    }

    private func collect(tag: String, command: String) async throws -> [IMAPResponse] {
        var untagged: [IMAPResponse] = []
        while true {
            let raw = try await readResponse()
            let response: IMAPResponse
            do {
                response = try IMAPParser.parse(raw)
            } catch {
                // One response we cannot read must not break the whole command: log it and go on.
                let firstLine = Self.firstLine(raw)
                syncLog.error("IMAP \(command, privacy: .public): unparsable response (\(raw.count) B): \(firstLine, privacy: .public)")
                if firstLine.hasPrefix(tag + " ") {
                    let status = firstLine.dropFirst(tag.count + 1).prefix { $0 != " " }.uppercased()
                    guard status == "OK" else {
                        throw IMAPError.commandFailed(command: command, status: status, text: firstLine)
                    }
                    return untagged
                }
                continue
            }
            if case .status(let t?, let kind, _, let text) = response, t == tag {
                guard kind == "OK" else {
                    throw IMAPError.commandFailed(command: command, status: kind, text: text)
                }
                return untagged
            }
            if case .status(nil, "BYE", _, let text) = response {
                connection = nil
                throw IMAPError.commandFailed(command: command, status: "BYE", text: text)
            }
            untagged.append(response)
        }
    }

    /// First line of a raw response (without literal contents), shortened for logs.
    static func firstLine(_ raw: Data) -> String {
        let line = raw.prefix { $0 != 0x0D && $0 != 0x0A }.prefix(400)
        return String(decoding: line, as: UTF8.self)
    }

    /// Reads a full response: one line plus any `{n}` literals and the lines that follow them.
    private func readResponse() async throws -> Data {
        guard let connection else { throw ConnectionError.closed }
        var data = Data()
        while true {
            let line = try await connection.readLine()
            data.append(line)
            guard let count = Self.literalLength(atEndOf: line) else { return data }
            data.append(try await connection.readBytes(count))
        }
    }

    static func literalLength(atEndOf line: Data) -> Int? {
        // line ends with "{123}\r\n" or "{123+}\r\n"
        guard line.count >= 5, line[line.endIndex - 3] == UInt8(ascii: "}") else { return nil }
        let bytes = line.dropLast(3)
        guard let open = bytes.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        let digits = String(decoding: bytes[(open + 1)...], as: UTF8.self).replacingOccurrences(of: "+", with: "")
        return Int(digits)
    }

    private func quote(_ string: String) -> String {
        Self.quoted(string)
    }

    public static func quoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Compresses UIDs into an IMAP sequence set, e.g. `1:5,7,9:12`.
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
