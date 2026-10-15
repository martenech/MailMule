import Foundation

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var address: String

    public init(name: String?, address: String) {
        self.name = name?.isEmpty == true ? nil : name
        self.address = address
    }

    public var displayName: String { name ?? address }

    /// `"Name" <addr>` with the name RFC 2047-encoded when it is not plain ASCII.
    public var headerValue: String {
        guard let name else { return address }
        if name.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\\" }) {
            return "\"\(name)\" <\(address)>"
        }
        return "\(EncodedWord.encode(name)) <\(address)>"
    }
}

enum Charset {
    static func encoding(named name: String) -> String.Encoding? {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        if cleaned == "utf-8" || cleaned == "utf8" { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(cleaned as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset), let s = String(data: data, encoding: encoding) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1250) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

/// RFC 2047 encoded words (`=?utf-8?B?...?=`).
public enum EncodedWord {
    private static let regex = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)

    public static func decode(_ input: String) -> String {
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two adjacent encoded words is dropped.
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1)).components(separatedBy: "*")[0]
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))
            let data: Data?
            if mode == "B" {
                data = Data(base64Encoded: padBase64(text))
            } else {
                data = QuotedPrintable.decode(text.replacingOccurrences(of: "_", with: " "), isHeader: true)
            }
            if let data {
                result += Charset.decode(data, charset: charset)
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    public static func encode(_ input: String) -> String {
        if input.allSatisfy(\.isASCII) { return input }
        // Split into chunks so each encoded word stays under 75 characters.
        var words: [String] = []
        var current = ""
        for ch in input {
            let candidate = current + String(ch)
            if Data(candidate.utf8).base64EncodedString().count > 45 {
                words.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func padBase64(_ s: String) -> String {
        let remainder = s.count % 4
        return remainder == 0 ? s : s + String(repeating: "=", count: 4 - remainder)
    }
}

public enum QuotedPrintable {
    public static func decode(_ input: String, isHeader: Bool = false) -> Data {
        var out = Data()
        let bytes = Array(input.utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "=") {
                // Soft line break.
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let hex = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    out.append(hex)
                    i += 3
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

public enum AddressParser {
    /// Parses `"Name" <a@b>, c@d, =?utf-8?...?= <e@f>`.
    public static func parseList(_ raw: String) -> [EmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "<" { inAngle = true }
            if ch == ">" { inAngle = false }
            if (ch == "," || ch == ";") && !inQuotes && !inAngle {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.compactMap(parse)
    }

    public static func parse(_ raw: String) -> EmailAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            return EmailAddress(name: EncodedWord.decode(name), address: address)
        }
        guard trimmed.contains("@") else { return nil }
        return EmailAddress(name: nil, address: trimmed)
    }
}

public enum MailDate {
    private static let zonedFormats = [
        "d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm Z",
        "dd-MMM-yyyy HH:mm:ss Z", // IMAP INTERNALDATE
    ]

    /// Some mailers leave the zone out; the sender's local time is the best guess we have.
    private static let localFormats = [
        "d MMM yyyy HH:mm:ss",
        "d MMM yyyy HH:mm",
    ]

    private static let zoneNames: [String: String] = [
        "UT": "+0000", "UTC": "+0000", "GMT": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "CET": "+0100", "CEST": "+0200", "MET": "+0100", "MEST": "+0200",
    ]

    /// Lenient RFC 5322 date parsing: any letter case, missing weekday or zone, zone names, 2-digit years.
    public static func parse(_ raw: String) -> Date? {
        // Drop comments like "(CET)" and collapse whitespace.
        var cleaned = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // The weekday adds nothing and is often malformed ("fri,", "Fri ").
        cleaned = cleaned.replacingOccurrences(of: #"^[A-Za-z]{2,9},?\s*"#, with: "", options: .regularExpression)
        // Month names in any case: "may" → "May".
        if let range = cleaned.range(of: #"(?<=^\d{1,2}[ -])[A-Za-z]{3}"#, options: .regularExpression) {
            cleaned.replaceSubrange(range, with: cleaned[range].capitalized)
        }
        // Two-digit years (RFC 5322 §4.3): 00–49 → 20xx, 50–99 → 19xx.
        if let range = cleaned.range(of: #"(?<=^\d{1,2} [A-Za-z]{3} )\d{2}(?= )"#, options: .regularExpression),
           let year = Int(cleaned[range]) {
            cleaned.replaceSubrange(range, with: String(year < 50 ? 2000 + year : 1900 + year))
        }
        // Zone names at the end → numeric offsets.
        if let last = cleaned.split(separator: " ").last, let offset = zoneNames[last.uppercased()] {
            cleaned = cleaned.dropLast(last.count) + offset
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in zonedFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        formatter.timeZone = .current
        for format in localFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
