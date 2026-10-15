import Foundation

/// The MIME structure of a message as the server describes it (IMAP BODYSTRUCTURE), used to download
/// only text and HTML parts and leave attachments on the server.
public indirect enum BodyStructure: Equatable, Sendable {
    case multipart(subtype: String, params: [String: String], parts: [BodyStructure])
    case single(Single)

    public struct Single: Equatable, Sendable {
        public let type: String
        public let subtype: String
        public let params: [String: String]
        public let encoding: String
        public let size: Int
        public let disposition: String?
        public let dispositionParams: [String: String]

        public var mimeType: String { "\(type)/\(subtype)" }

        /// Text and HTML that is not an attachment is downloaded; everything else is left on the server.
        public var isBodyText: Bool {
            type == "text" && (subtype == "plain" || subtype == "html") && disposition != "attachment"
        }
    }

    public static func parse(_ value: IMAPValue) -> BodyStructure? {
        guard let items = value.list, !items.isEmpty else { return nil }
        if items.first?.list != nil {
            // Multipart: child bodies, then subtype, then extension data (params, disposition, …).
            let children = items.prefix { $0.list != nil }.compactMap(parse)
            let rest = Array(items.dropFirst(children.count))
            let subtype = rest.first?.text?.lowercased() ?? "mixed"
            let params = rest.count > 1 ? Self.params(rest[1]) : [:]
            return .multipart(subtype: subtype, params: params, parts: children)
        }
        guard items.count >= 7 else { return nil }
        let type = items[0].text?.lowercased() ?? "application"
        let subtype = items[1].text?.lowercased() ?? "octet-stream"
        // Extension data starts after the type-specific fields: lines for text, envelope/body/lines for messages.
        let extensionStart = type == "text" ? 8 : (type == "message" && subtype == "rfc822") ? 10 : 7
        let dispositionIndex = extensionStart + 1
        var disposition: String?
        var dispositionParams: [String: String] = [:]
        if items.count > dispositionIndex, let list = items[dispositionIndex].list, let kind = list.first?.text {
            disposition = kind.lowercased()
            if list.count > 1 { dispositionParams = Self.params(list[1]) }
        }
        return .single(Single(
            type: type,
            subtype: subtype,
            params: Self.params(items[2]),
            encoding: items[5].text?.lowercased() ?? "7bit",
            size: items[6].text.flatMap(Int.init) ?? 0,
            disposition: disposition,
            dispositionParams: dispositionParams
        ))
    }

    private static func params(_ value: IMAPValue) -> [String: String] {
        guard let list = value.list else { return [:] }
        var result: [String: String] = [:]
        var i = 0
        while i + 1 < list.count {
            if let key = list[i].text, let val = list[i + 1].text { result[key.lowercased()] = val }
            i += 2
        }
        return result
    }

    /// Leaf parts with their IMAP section numbers ("1", "1.2", …).
    public func leaves(prefix: String = "") -> [(section: String, part: Single)] {
        switch self {
        case .single(let part):
            return [(prefix.isEmpty ? "1" : prefix, part)]
        case .multipart(_, _, let parts):
            return parts.enumerated().flatMap { offset, child in
                child.leaves(prefix: prefix.isEmpty ? "\(offset + 1)" : "\(prefix).\(offset + 1)")
            }
        }
    }

    /// Whether skipping attachments saves anything: a multipart message with at least one non-text part.
    public var hasDeferrableParts: Bool {
        guard case .multipart = self else { return false }
        return leaves().contains { !$0.part.isBodyText }
    }

    /// IMAP fetch items for a partial download: the header, each part's MIME header and the text parts.
    public var partialFetchItems: [String] {
        ["BODY.PEEK[HEADER]"] + leaves().flatMap { section, part in
            part.isBodyText ? ["BODY.PEEK[\(section).MIME]", "BODY.PEEK[\(section)]"] : ["BODY.PEEK[\(section).MIME]"]
        }
    }

    /// Rebuilds the message from fetched pieces: text parts complete, attachments as empty stubs that
    /// keep their headers (name, type) plus `X-Mailmule-Stub: <size>`.
    public func partialMessage(from fetched: [String: IMAPValue]) -> Data? {
        guard let header = fetched["BODY[HEADER]"]?.data else { return nil }
        var out = PartialMessage.insertHeader("X-Mailmule-Partial: 1", into: header)
        guard render(prefix: "", fetched: fetched, into: &out, isTop: true) else { return nil }
        return out
    }

    private func render(prefix: String, fetched: [String: IMAPValue], into out: inout Data, isTop: Bool) -> Bool {
        switch self {
        case .multipart(let subtype, let params, let parts):
            let boundary = params["boundary"] ?? "mailmule-\(UUID().uuidString)"
            if !isTop {
                out.append(Data("Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\r\n\r\n".utf8))
            }
            for (offset, child) in parts.enumerated() {
                let section = prefix.isEmpty ? "\(offset + 1)" : "\(prefix).\(offset + 1)"
                out.append(Data("--\(boundary)\r\n".utf8))
                guard child.render(prefix: section, fetched: fetched, into: &out, isTop: false) else { return false }
                out.append(Data("\r\n".utf8))
            }
            out.append(Data("--\(boundary)--\r\n".utf8))
            return true
        case .single(let part):
            guard let mime = fetched["BODY[\(prefix).MIME]"]?.data else { return false }
            if part.isBodyText {
                guard let body = fetched["BODY[\(prefix)]"]?.data else { return false }
                out.append(mime)
                out.append(body)
            } else {
                out.append(PartialMessage.insertHeader("X-Mailmule-Stub: \(part.size)", into: mime))
            }
            return true
        }
    }
}

enum PartialMessage {
    /// Adds a header line just before the blank line that ends a header block.
    static func insertHeader(_ line: String, into header: Data) -> Data {
        let crlf = Data("\r\n\r\n".utf8)
        if let range = header.range(of: crlf) {
            var out = Data(header[header.startIndex..<range.lowerBound])
            out.append(Data("\r\n\(line)\r\n\r\n".utf8))
            return out
        }
        var out = header
        if !out.isEmpty && !out.ends(with: Data("\r\n".utf8)) { out.append(Data("\r\n".utf8)) }
        out.append(Data("\(line)\r\n\r\n".utf8))
        return out
    }
}

extension Data {
    func ends(with suffix: Data) -> Bool {
        count >= suffix.count && self[(endIndex - suffix.count)...] == suffix
    }
}
