import Foundation

/// Header field list that preserves order and allows case-insensitive lookup.
public struct MIMEHeaders: Sendable {
    public private(set) var fields: [(name: String, value: String)] = []

    init(raw: Data) {
        let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
        var current: (String, String)?
        for line in text.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.first == " " || line.first == "\t" {
                // Folded continuation line.
                current?.1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let current { fields.append(current) }
            current = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            current = (name, value)
        }
        if let current { fields.append(current) }
    }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Header value with RFC 2047 words decoded.
    public func decoded(_ name: String) -> String? {
        self[name].map(EncodedWord.decode)
    }
}

/// `type/subtype; key=value; ...` style header.
public struct HeaderParameters: Sendable {
    public let value: String
    public let parameters: [String: String]

    public init(_ raw: String?) {
        guard let raw else {
            value = ""
            parameters = [:]
            return
        }
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        value = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        var params: [String: String] = [:]
        var continuations: [String: [(Int, String)]] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            // RFC 2231: filename*=utf-8''n%C3%A1zov or filename*0*=...
            if key.hasSuffix("*") {
                key.removeLast()
                if let quote = val.range(of: "''") {
                    let charset = String(val[..<quote.lowerBound])
                    let encoded = String(val[quote.upperBound...])
                    val = Self.percentDecode(encoded, charset: charset)
                } else {
                    val = Self.percentDecode(val, charset: "utf-8")
                }
            }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((index, val))
                continue
            }
            params[key] = val
        }
        for (key, pieces) in continuations {
            params[key] = pieces.sorted { $0.0 < $1.0 }.map(\.1).joined()
        }
        parameters = params
    }

    private static func percentDecode(_ s: String, charset: String) -> String {
        var bytes: [UInt8] = []
        var iterator = Array(s.utf8).makeIterator()
        while let c = iterator.next() {
            if c == UInt8(ascii: "%"), let h = iterator.next(), let l = iterator.next(),
               let v = UInt8(String(decoding: [h, l], as: UTF8.self), radix: 16) {
                bytes.append(v)
            } else {
                bytes.append(c)
            }
        }
        return Charset.decode(Data(bytes), charset: charset.isEmpty ? "utf-8" : charset)
    }
}

public struct MIMEPart: Sendable {
    public let headers: MIMEHeaders
    /// The header block exactly as received, for re-serializing without changes.
    let rawHeaders: Data
    public let contentType: HeaderParameters
    public let body: Data
    public let children: [MIMEPart]

    public var mimeType: String { contentType.value.isEmpty ? "text/plain" : contentType.value }
    public var isMultipart: Bool { mimeType.hasPrefix("multipart/") }

    public var disposition: HeaderParameters { HeaderParameters(headers["Content-Disposition"]) }

    public var filename: String? {
        let name = disposition.parameters["filename"] ?? contentType.parameters["name"]
        return name.map(EncodedWord.decode)
    }

    /// Size of an attachment left on the server (attachments downloaded on demand); nil for real parts.
    public var stubSize: Int? {
        headers["X-Mailmule-Stub"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    public var isAttachment: Bool {
        if stubSize != nil { return true }
        if disposition.value == "attachment" { return true }
        if disposition.value == "inline", filename != nil, !mimeType.hasPrefix("text/") { return true }
        return filename != nil && !mimeType.hasPrefix("text/")
    }

    /// Body with Content-Transfer-Encoding removed.
    public var decodedBody: Data {
        let encoding = headers["Content-Transfer-Encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
        switch encoding {
        case "base64":
            let cleaned = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: EncodedWord.padBase64(cleaned)) ?? Data()
        case "quoted-printable":
            return QuotedPrintable.decode(String(decoding: body, as: UTF8.self))
        default:
            return body
        }
    }

    public var text: String {
        Charset.decode(decodedBody, charset: contentType.parameters["charset"])
    }

    /// Depth-first list of leaf parts.
    public var leaves: [MIMEPart] {
        isMultipart ? children.flatMap(\.leaves) : [self]
    }

    init(data: Data) {
        let (headerData, bodyData) = Self.splitHeaders(data)
        rawHeaders = Data(headerData)
        headers = MIMEHeaders(raw: headerData)
        contentType = HeaderParameters(headers["Content-Type"])
        body = bodyData
        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"] {
            children = Self.splitMultipart(bodyData, boundary: boundary).map(MIMEPart.init(data:))
        } else {
            children = []
        }
    }

    static func splitHeaders(_ data: Data) -> (Data, Data) {
        if let range = data.firstRange(of: Data("\r\n\r\n".utf8)) {
            return (data[data.startIndex..<range.lowerBound], data[range.upperBound...])
        }
        if let range = data.firstRange(of: Data("\n\n".utf8)) {
            return (data[data.startIndex..<range.lowerBound], data[range.upperBound...])
        }
        return (data, Data())
    }

    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchStart = data.startIndex
        var partStart: Data.Index?

        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            // The delimiter must be at the start of a line.
            let atLineStart = range.lowerBound == data.startIndex || data[range.lowerBound - 1] == 0x0A
            guard atLineStart else {
                searchStart = range.upperBound
                continue
            }
            if let start = partStart {
                var end = range.lowerBound
                if end > start, data[end - 1] == 0x0A { end -= 1 }
                if end > start, data[end - 1] == 0x0D { end -= 1 }
                parts.append(Data(data[start..<end]))
            }
            var after = range.upperBound
            // Closing delimiter "--boundary--".
            if after + 1 < data.endIndex, data[after] == UInt8(ascii: "-"), data[after + 1] == UInt8(ascii: "-") {
                break
            }
            // Skip transport padding and the line break.
            while after < data.endIndex, data[after] != 0x0A { after += 1 }
            partStart = min(after + 1, data.endIndex)
            searchStart = partStart!
        }
        return parts
    }
}

public struct Attachment: Sendable, Hashable {
    public let filename: String
    public let mimeType: String
    public let size: Int

    public init(filename: String, mimeType: String, size: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

/// A parsed RFC 5322 message.
public struct MIMEMessage: Sendable {
    public let root: MIMEPart

    public init(data: Data) {
        root = MIMEPart(data: data)
    }

    public var headers: MIMEHeaders { root.headers }

    /// Downloaded without attachment contents; the full message must be fetched before using them.
    public var isPartial: Bool { headers["X-Mailmule-Partial"] != nil }

    public var subject: String { headers.decoded("Subject") ?? "" }
    public var from: EmailAddress? { headers["From"].flatMap { AddressParser.parseList($0).first } }
    public var to: [EmailAddress] { headers["To"].map(AddressParser.parseList) ?? [] }
    public var cc: [EmailAddress] { headers["Cc"].map(AddressParser.parseList) ?? [] }
    public var replyTo: [EmailAddress] { headers["Reply-To"].map(AddressParser.parseList) ?? [] }
    public var date: Date? { headers["Date"].flatMap(MailDate.parse) }

    /// When the message arrived: the date of the topmost Received header ("…; Fri, 20 May 2022 12:25:43 +0200").
    public var receivedDate: Date? { Self.receivedDate(headers) }

    /// The Date header, or the arrival time when Date is missing or unreadable.
    public var bestDate: Date? { date ?? receivedDate }

    static func receivedDate(_ headers: MIMEHeaders) -> Date? {
        guard let received = headers["Received"], let semicolon = received.lastIndex(of: ";") else { return nil }
        return MailDate.parse(String(received[received.index(after: semicolon)...]))
    }

    /// Date from just the header block of a raw message (no need to read attachments).
    public static func bestDate(headerData: Data) -> Date? {
        let headers = MIMEHeaders(raw: MIMEPart.splitHeaders(headerData).0)
        return headers["Date"].flatMap(MailDate.parse) ?? receivedDate(headers)
    }

    public var messageID: String? { headers["Message-ID"].flatMap { Self.messageIDs(in: $0).first } }
    public var inReplyTo: String? { headers["In-Reply-To"].flatMap { Self.messageIDs(in: $0).first } }
    public var references: [String] { headers["References"].map(Self.messageIDs(in:)) ?? [] }

    public var plainText: String? {
        root.leaves.first { $0.mimeType == "text/plain" && !$0.isAttachment }?.text
    }

    public var html: String? {
        root.leaves.first { $0.mimeType == "text/html" && !$0.isAttachment }?.text
    }

    /// Plain text, or text extracted from HTML when the message has no plain part.
    public var bestText: String {
        if let plain = plainText, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
        if let html { return HTMLText.extract(html) }
        return ""
    }

    public var attachments: [Attachment] {
        root.leaves.filter(\.isAttachment).map {
            Attachment(filename: $0.filename ?? "príloha", mimeType: $0.mimeType, size: $0.stubSize ?? $0.decodedBody.count)
        }
    }

    /// Extracts `<id>` tokens and returns them without angle brackets.
    static func messageIDs(in raw: String) -> [String] {
        var ids: [String] = []
        var current: String?
        for ch in raw {
            if ch == "<" { current = "" }
            else if ch == ">" {
                if let c = current, !c.isEmpty { ids.append(c) }
                current = nil
            } else if current != nil {
                current!.append(ch)
            }
        }
        if ids.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("@") { ids.append(trimmed) }
        }
        return ids
    }
}

public enum HTMLText {
    /// Rough HTML to text conversion used for snippets, search and markdown export.
    public static func extract(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|blockquote)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turns a complete stored message into a partial one: attachment contents are dropped (they stay on
/// the server), text parts and all headers are kept.
public enum AttachmentStripper {
    /// The stripped message, or nil when there is nothing to strip.
    public static func strip(_ data: Data) -> Data? {
        let message = MIMEMessage(data: data)
        guard !message.isPartial, message.root.isMultipart,
              message.root.leaves.contains(where: { $0.isAttachment }) else { return nil }
        var out = PartialMessage.insertHeader("X-Mailmule-Partial: 1", into: message.root.rawHeaders + Data("\r\n\r\n".utf8))
        render(message.root, into: &out, isTop: true)
        return out
    }

    private static func render(_ part: MIMEPart, into out: inout Data, isTop: Bool) {
        if part.isMultipart, let boundary = part.contentType.parameters["boundary"] {
            if !isTop {
                out.append(part.rawHeaders)
                out.append(Data("\r\n\r\n".utf8))
            }
            for child in part.children {
                out.append(Data("--\(boundary)\r\n".utf8))
                render(child, into: &out, isTop: false)
                out.append(Data("\r\n".utf8))
            }
            out.append(Data("--\(boundary)--\r\n".utf8))
        } else if part.isAttachment {
            let size = part.stubSize ?? part.decodedBody.count
            out.append(PartialMessage.insertHeader("X-Mailmule-Stub: \(size)", into: part.rawHeaders + Data("\r\n\r\n".utf8)))
        } else {
            out.append(part.rawHeaders)
            out.append(Data("\r\n\r\n".utf8))
            out.append(part.body)
        }
    }
}

// MARK: - Images in HTML

/// The HTML part ready for display: `cid:` references to images inside the message become `data:` URLs.
public struct DisplayHTML: Sendable {
    public let html: String
    /// Inline images whose data is not stored locally (left on the server with "attachments on demand").
    public let missingInlineImages: Int
    /// Images loaded from the internet (blocked by default, they can tell the sender you opened the mail).
    public let hasRemoteImages: Bool
}

extension MIMEPart {
    /// `Content-ID` without angle brackets.
    public var contentID: String? {
        guard let raw = headers["Content-ID"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }
}

extension MIMEMessage {
    public var displayHTML: DisplayHTML? {
        guard var html else { return nil }
        let parts = Dictionary(root.leaves.compactMap { part in part.contentID.map { ($0.lowercased(), part) } },
                               uniquingKeysWith: { first, _ in first })
        var missing = 0
        if let regex = try? NSRegularExpression(pattern: #"cid:([^"'\s)>]+)"#, options: .caseInsensitive) {
            let source = html as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let id = (source.substring(with: match.range(at: 1)).removingPercentEncoding ?? source.substring(with: match.range(at: 1))).lowercased()
                if let part = parts[id], part.stubSize == nil, !part.decodedBody.isEmpty {
                    result += "data:\(part.mimeType);base64,\(part.decodedBody.base64EncodedString())"
                } else {
                    if parts[id] != nil { missing += 1 }
                    result += source.substring(with: match.range)
                }
                last = match.range.location + match.range.length
            }
            result += source.substring(from: last)
            html = result
        }
        return DisplayHTML(html: html, missingInlineImages: missing, hasRemoteImages: Self.hasRemoteImages(html))
    }

    /// `<img src="http…">`, `background="http…"` or CSS `url(http…)`.
    static func hasRemoteImages(_ html: String) -> Bool {
        let pattern = #"(?i)(<img\b[^>]*\bsrc\s*=\s*["']?\s*(https?:)?//|\bbackground\s*=\s*["']?\s*https?://|url\(\s*["']?\s*https?://)"#
        return html.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Removes tracking pixels: images sized 1×1 (or hidden) and images from known open-tracking URLs.
/// Used when images from the internet are loaded, so the sender does not learn the mail was opened.
public enum TrackerFilter {
    private static let trackingURLParts = [
        "/track/open", "/wf/open", "open.php", "/open.aspx", "/e/o/", "/trk/", "pixel.gif", "/pixel",
        "beacon", "/tracking/", "mailtrack", "t.hubspotemail", "list-manage.com/track", "emltrk.com",
        "/o.gif", "/open?", "/open/", "openrate", "spacer.gif",
    ]

    public static func strip(_ html: String) -> (html: String, removed: Int) {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive) else {
            return (html, 0)
        }
        let source = html as NSString
        var result = ""
        var last = 0
        var removed = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range)
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            if isTracker(tag) {
                removed += 1
            } else {
                result += tag
            }
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return (result, removed)
    }

    static func isTracker(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        guard let src = attribute("src", in: lower), src.hasPrefix("http") || src.hasPrefix("//") else { return false }
        if trackingURLParts.contains(where: src.contains) { return true }
        let style = (attribute("style", in: lower) ?? "").replacingOccurrences(of: " ", with: "")
        if style.contains("display:none") || style.contains("visibility:hidden") { return true }
        let width = size(attribute("width", in: lower)) ?? cssSize("width", in: style)
        let height = size(attribute("height", in: lower)) ?? cssSize("height", in: style)
        if let width, let height { return width <= 1 && height <= 1 }
        return width.map { $0 <= 1 } ?? height.map { $0 <= 1 } ?? false
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private static func size(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: "px", with: ""))
    }

    private static func cssSize(_ property: String, in style: String) -> Double? {
        guard let range = style.range(of: #"(^|;)"# + property + #":[0-9.]+px"#, options: .regularExpression) else { return nil }
        let value = style[range].split(separator: ":").last.map(String.init) ?? ""
        return Double(value.replacingOccurrences(of: "px", with: ""))
    }
}
