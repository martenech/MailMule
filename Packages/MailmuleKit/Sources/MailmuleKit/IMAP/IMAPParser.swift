import Foundation

/// A parsed IMAP data item: atoms, strings (quoted or literal), parenthesized lists and NIL.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let s): s
        case .string(let d): String(decoding: d, as: UTF8.self)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let d): d
        case .atom(let s): Data(s.utf8)
        default: nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

public enum IMAPResponse: Sendable {
    /// `* OK/NO/BAD/BYE/PREAUTH [code] text` or `TAG OK ...`
    case status(tag: String?, kind: String, code: String?, text: String)
    /// `* 12 FETCH (...)`, `* 5 EXISTS`, ...
    case numbered(number: UInt32, kind: String, values: [IMAPValue])
    /// `* LIST (...) "/" name`, `* SEARCH 1 2 3`, `* CAPABILITY ...`
    case data(kind: String, values: [IMAPValue])
    case continuation(String)
}

public enum IMAPParseError: Error, LocalizedError {
    case unexpectedEnd
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd: "Neúplná odpoveď IMAP servera."
        case .malformed(let detail): "Nezrozumiteľná odpoveď IMAP servera: \(detail)"
        }
    }
}

/// Parses one complete IMAP response (a line plus any embedded `{n}\r\n` literals).
public struct IMAPParser {
    private let bytes: [UInt8]
    private var pos = 0

    public init(_ data: Data) {
        bytes = Array(data)
    }

    public static func parse(_ data: Data) throws -> IMAPResponse {
        var parser = IMAPParser(data)
        return try parser.parseResponse()
    }

    mutating func parseResponse() throws -> IMAPResponse {
        if peek() == UInt8(ascii: "+") {
            pos += 1
            return .continuation(restOfLine())
        }
        let tagToken = readUntilSpace()
        skipSpaces()
        let tag: String? = tagToken == "*" ? nil : tagToken

        let first = readUntilSpace()
        skipSpaces()

        if let number = UInt32(first) {
            let kind = readUntilSpace().uppercased()
            skipSpaces()
            let values = try parseValues()
            return .numbered(number: number, kind: kind, values: values)
        }

        let kind = first.uppercased()
        if ["OK", "NO", "BAD", "BYE", "PREAUTH"].contains(kind) {
            var code: String?
            if peek() == UInt8(ascii: "[") {
                let start = pos
                var depth = 0
                while pos < bytes.count {
                    let c = bytes[pos]
                    if c == UInt8(ascii: "[") { depth += 1 }
                    if c == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { pos += 1; break }
                    }
                    pos += 1
                }
                code = String(decoding: bytes[(start + 1)..<(pos - 1)], as: UTF8.self)
                skipSpaces()
            }
            return .status(tag: tag, kind: kind, code: code, text: restOfLine())
        }

        if tag != nil {
            throw IMAPParseError.malformed("Unexpected tagged response \(kind)")
        }
        return .data(kind: kind, values: try parseValues())
    }

    private mutating func parseValues() throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard let c = peek(), c != 0x0D, c != 0x0A else { break }
            values.append(try parseValue())
        }
        return values
    }

    mutating func parseValue() throws -> IMAPValue {
        guard let c = peek() else { throw IMAPParseError.unexpectedEnd }
        switch c {
        case UInt8(ascii: "("):
            pos += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let next = peek() else { throw IMAPParseError.unexpectedEnd }
                if next == UInt8(ascii: ")") {
                    pos += 1
                    break
                }
                items.append(try parseValue())
            }
            return .list(items)
        case UInt8(ascii: "\""):
            return .string(try parseQuoted())
        case UInt8(ascii: "{"):
            return .string(try parseLiteral())
        default:
            let atom = parseAtom()
            if atom.isEmpty { throw IMAPParseError.malformed("Empty atom at \(pos)") }
            if atom.uppercased() == "NIL" { return .nil_ }
            return .atom(atom)
        }
    }

    private mutating func parseQuoted() throws -> Data {
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count {
            let c = bytes[pos]
            if c == UInt8(ascii: "\\"), pos + 1 < bytes.count {
                out.append(bytes[pos + 1])
                pos += 2
                continue
            }
            if c == UInt8(ascii: "\"") {
                pos += 1
                return Data(out)
            }
            out.append(c)
            pos += 1
        }
        throw IMAPParseError.unexpectedEnd
    }

    private mutating func parseLiteral() throws -> Data {
        pos += 1
        var digits = ""
        while let c = peek(), c != UInt8(ascii: "}") {
            if c != UInt8(ascii: "+") { digits.append(Character(UnicodeScalar(c))) }
            pos += 1
        }
        pos += 1 // }
        guard peek() == 0x0D else { throw IMAPParseError.malformed("Literal without CRLF") }
        pos += 2
        guard let count = Int(digits), pos + count <= bytes.count else { throw IMAPParseError.unexpectedEnd }
        let data = Data(bytes[pos..<(pos + count)])
        pos += count
        return data
    }

    /// Atoms may contain `[...]` sections with spaces and parens, e.g. `BODY[HEADER.FIELDS (MESSAGE-ID)]`.
    private mutating func parseAtom() -> String {
        let start = pos
        var bracketDepth = 0
        while pos < bytes.count {
            let c = bytes[pos]
            if c == UInt8(ascii: "[") { bracketDepth += 1 }
            if c == UInt8(ascii: "]") { bracketDepth -= 1 }
            if bracketDepth == 0 {
                if c == UInt8(ascii: " ") || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")
                    || c == 0x0D || c == 0x0A || c == UInt8(ascii: "\"") {
                    break
                }
            }
            pos += 1
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private func peek() -> UInt8? {
        pos < bytes.count ? bytes[pos] : nil
    }

    private mutating func skipSpaces() {
        while let c = peek(), c == UInt8(ascii: " ") { pos += 1 }
    }

    private mutating func readUntilSpace() -> String {
        let start = pos
        while let c = peek(), c != UInt8(ascii: " "), c != 0x0D, c != 0x0A { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private mutating func restOfLine() -> String {
        let start = pos
        while let c = peek(), c != 0x0D, c != 0x0A { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

extension Array where Element == IMAPValue {
    /// Treats a FETCH attribute list `(KEY value KEY value ...)` as a dictionary with uppercased keys.
    public func fetchAttributes() -> [String: IMAPValue] {
        var result: [String: IMAPValue] = [:]
        var i = 0
        while i + 1 < count {
            if let key = self[i].text {
                result[key.uppercased()] = self[i + 1]
            }
            i += 2
        }
        return result
    }
}
