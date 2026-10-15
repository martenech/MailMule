import Foundation

/// A search like Gmail's: free text plus operators, e.g. `from:dodavatel has:attachment after:2026-09 faktúra`.
/// Slovak spellings work too: `od:`, `komu:`, `predmet:`, `má:prílohu`, `je:neprečítané`, `po:`, `pred:`.
public struct SearchQuery: Equatable, Sendable {
    public var text: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var subject: [String] = []
    /// `s:jan@x.sk`: mail from or to this person.
    public var with: [String] = []
    public var hasAttachment = false
    public var unread: Bool?
    public var starred = false
    public var after: Date?
    public var before: Date?

    public init(_ input: String) {
        for token in Self.tokens(input) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                text.append(token)
                continue
            }
            let key = Self.fold(String(token[..<colon]))
            let value = String(token[token.index(after: colon)...])
            guard !value.isEmpty else { text.append(token); continue }
            let folded = Self.fold(value)
            switch key {
            case "from", "od": from.append(value)
            case "to", "komu", "cc": to.append(value)
            case "subject", "predmet": subject.append(value)
            case "s", "with": with.append(value)
            case "has", "ma" where ["attachment", "attachments", "prilohu", "prilohy", "priloha"].contains(folded):
                hasAttachment = true
            case "is", "je":
                switch folded {
                case "unread", "neprecitane", "neprecitana": unread = true
                case "read", "precitane", "precitana": unread = false
                case "starred", "hviezdicka", "s hviezdickou", "oznacene": starred = true
                default: text.append(token)
                }
            case "after", "po", "od_datumu":
                if let date = Self.date(value) { after = date } else { text.append(token) }
            case "before", "pred":
                if let date = Self.date(value) { before = date } else { text.append(token) }
            default:
                // Not an operator (e.g. a time "10:30" or a URL): plain text.
                text.append(token)
            }
        }
    }

    public var isEmpty: Bool {
        text.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty && with.isEmpty && !hasAttachment && unread == nil
            && !starred && after == nil && before == nil
    }

    /// Words, keeping "quoted phrases" together.
    static func tokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in input {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// `2026-09-15`, `2026-09` (start of month), `2026`, or `15.9.2026`.
    static func date(_ value: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let numbers = value.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "/" }).compactMap { Int($0) }
        var parts = DateComponents()
        if value.contains("."), numbers.count == 3 {
            (parts.day, parts.month, parts.year) = (numbers[0], numbers[1], numbers[2])
        } else if numbers.count >= 1, numbers[0] > 1900 {
            parts.year = numbers[0]
            parts.month = numbers.count > 1 ? numbers[1] : 1
            parts.day = numbers.count > 2 ? numbers[2] : 1
        } else {
            return nil
        }
        return calendar.date(from: parts)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
