import Foundation

/// A meeting invitation (iCalendar, RFC 5545/5546) found in a message.
public struct CalendarInvite: Equatable, Sendable {
    public enum Method: String, Sendable {
        case request = "REQUEST", cancel = "CANCEL", reply = "REPLY", publish = "PUBLISH", other = ""
    }

    /// RFC 5545 participation status.
    public enum Status: String, Sendable, CaseIterable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED", needsAction = "NEEDS-ACTION"
    }

    public struct Attendee: Equatable, Sendable {
        public var address: String
        public var name: String?
        public var status: Status?
    }

    public var method: Method
    public var uid: String
    public var sequence: Int
    public var summary: String
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var details: String?
    public var organizer: EmailAddress?
    public var attendees: [Attendee]
    /// A video call link (Google Meet, Teams, Zoom) from the invite.
    public var conferenceURL: URL?
    public var isCancelled: Bool

    /// Your answer as the organizer last knew it.
    public func status(of addresses: [String]) -> Status? {
        let own = Set(addresses.map { $0.lowercased() })
        return attendees.first { own.contains($0.address.lowercased()) }?.status
    }

    // MARK: Parsing

    public init?(ics text: String) {
        let lines = Self.unfold(text)
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VEVENT") }) else { return nil }
        var method = Method.other
        var event: [(name: String, params: [String: String], value: String)] = []
        var inEvent = false
        var depth = 0
        for line in lines {
            let property = Self.property(line)
            switch (property.name, property.value.uppercased()) {
            case ("BEGIN", "VEVENT"):
                if event.isEmpty { inEvent = true }
            case ("END", "VEVENT"):
                inEvent = false
            case ("BEGIN", _) where inEvent:
                depth += 1 // VALARM inside the event
            case ("END", _) where inEvent && depth > 0:
                depth -= 1
            case ("METHOD", let value) where !inEvent:
                method = Method(rawValue: value) ?? .other
            default:
                if inEvent && depth == 0 { event.append(property) }
            }
        }
        func first(_ name: String) -> (name: String, params: [String: String], value: String)? {
            event.first { $0.name == name }
        }
        guard let uid = first("UID")?.value, !uid.isEmpty else { return nil }
        self.method = method
        self.uid = uid
        sequence = Int(first("SEQUENCE")?.value ?? "") ?? 0
        summary = Self.unescape(first("SUMMARY")?.value ?? "")
        let startProperty = first("DTSTART")
        let startDate = startProperty.flatMap { Self.date($0.value, params: $0.params) }
        start = startDate
        isAllDay = startProperty.map { $0.params["VALUE"]?.uppercased() == "DATE" || $0.value.count == 8 } ?? false
        end = first("DTEND").flatMap { Self.date($0.value, params: $0.params) }
            ?? first("DURATION").flatMap { Self.duration($0.value) }.flatMap { duration in startDate.map { $0 + duration } }
        location = first("LOCATION").map { Self.unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        details = first("DESCRIPTION").map { Self.unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        organizer = first("ORGANIZER").map { EmailAddress(name: $0.params["CN"].map(Self.unquote), address: Self.mailto($0.value)) }
            .flatMap { $0.address.contains("@") ? $0 : nil }
        attendees = event.filter { $0.name == "ATTENDEE" }.map {
            Attendee(address: Self.mailto($0.value), name: $0.params["CN"].map(Self.unquote),
                     status: $0.params["PARTSTAT"].flatMap { Status(rawValue: $0.uppercased()) })
        }
        let links = [first("X-GOOGLE-CONFERENCE")?.value, location, details].compactMap { $0 }
        conferenceURL = links.lazy.compactMap(Self.meetingLink).first
        isCancelled = method == .cancel || first("STATUS")?.value.uppercased() == "CANCELLED"
    }

    /// Joins folded lines (a line starting with a space or tab continues the previous one).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// `ATTENDEE;CN="Ján";PARTSTAT=ACCEPTED:mailto:jan@x.sk` → name, parameters, value.
    static func property(_ line: String) -> (name: String, params: [String: String], value: String) {
        var quoted = false
        var colon: String.Index?
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":" && !quoted { colon = index; break }
        }
        guard let colon else { return (line.uppercased(), [:], "") }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        quoted = false
        for character in head {
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { params[pair[0].uppercased()] = pair[1] }
        }
        return (parts[0].uppercased(), params, value)
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func mailto(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("mailto:") ? String(trimmed.dropFirst(7)) : trimmed
    }

    /// `20260922T150000Z` (UTC), `20260922T150000` with TZID (or floating = local), `20260922` (all day).
    static func date(_ value: String, params: [String: String]) -> Date? {
        let digits = value.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        if digits.hasSuffix("Z") {
            calendar.timeZone = TimeZone(identifier: "UTC")!
        } else if let tzid = params["TZID"].map(unquote), let zone = TimeZone(identifier: tzid) ?? windowsZone(tzid) {
            calendar.timeZone = zone
        } else {
            calendar.timeZone = .current
        }
        let plain = digits.replacingOccurrences(of: "Z", with: "")
        func number(_ from: Int, _ length: Int) -> Int? {
            guard plain.count >= from + length else { return nil }
            let start = plain.index(plain.startIndex, offsetBy: from)
            return Int(plain[start..<plain.index(start, offsetBy: length)])
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2) else { return nil }
        var parts = DateComponents(year: year, month: month, day: day)
        if plain.count >= 15 {
            parts.hour = number(9, 2)
            parts.minute = number(11, 2)
            parts.second = number(13, 2)
        }
        return calendar.date(from: parts)
    }

    /// Outlook sends Windows zone names ("Central Europe Standard Time").
    static func windowsZone(_ name: String) -> TimeZone? {
        let map = [
            "Central Europe Standard Time": "Europe/Bratislava", "Central European Standard Time": "Europe/Warsaw",
            "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
            "GMT Standard Time": "Europe/London", "E. Europe Standard Time": "Europe/Bucharest",
            "Eastern Standard Time": "America/New_York", "Pacific Standard Time": "America/Los_Angeles",
            "UTC": "UTC",
        ]
        return map[name].flatMap(TimeZone.init(identifier:))
    }

    /// `PT1H30M`, `P1D` → seconds.
    static func duration(_ value: String) -> TimeInterval? {
        var seconds: TimeInterval = 0
        var number = ""
        for character in value.uppercased() {
            if character.isNumber { number.append(character); continue }
            let amount = Double(number) ?? 0
            switch character {
            case "W": seconds += amount * 7 * 86_400
            case "D": seconds += amount * 86_400
            case "H": seconds += amount * 3_600
            case "M": seconds += amount * 60
            case "S": seconds += amount
            default: break
            }
            number = ""
        }
        return seconds > 0 ? seconds : nil
    }

    static func meetingLink(_ text: String) -> URL? {
        let pattern = #"https://(meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|[a-z0-9.-]*zoom\.us)/[^\s"<>\\]+"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return URL(string: String(text[range]))
    }

    // MARK: Answering

    /// The METHOD:REPLY calendar sent back to the organizer.
    public func reply(_ status: Status, from attendee: EmailAddress, at now: Date = Date()) -> String {
        let stamp = Self.utcStamp(now)
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Mailmule//Mailmule//SK",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "SEQUENCE:\(sequence)",
            "DTSTAMP:\(stamp)",
        ]
        if let start { lines.append(isAllDay ? "DTSTART;VALUE=DATE:\(Self.dayStamp(start))" : "DTSTART:\(Self.utcStamp(start))") }
        if let end { lines.append(isAllDay ? "DTEND;VALUE=DATE:\(Self.dayStamp(end))" : "DTEND:\(Self.utcStamp(end))") }
        if let organizer {
            let name = organizer.name.map { ";CN=\(Self.quoteParam($0))" } ?? ""
            lines.append("ORGANIZER\(name):mailto:\(organizer.address)")
        }
        let name = attendee.name.map { ";CN=\(Self.quoteParam($0))" } ?? ""
        lines.append("ATTENDEE;PARTSTAT=\(status.rawValue)\(name):mailto:\(attendee.address)")
        lines.append("SUMMARY:\(Self.escape(summary))")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(Self.fold).joined(separator: "\r\n") + "\r\n"
    }

    static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func quoteParam(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    /// Lines longer than 75 octets are folded (RFC 5545).
    static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for character in line {
            let size = String(character).utf8.count
            if count + size > 74 {
                result += "\r\n "
                count = 1
            }
            result.append(character)
            count += size
        }
        return result
    }
}

extension MIMEMessage {
    /// The meeting invitation in this message: a text/calendar part or an attached .ics file.
    public var invite: CalendarInvite? {
        let part = root.leaves.first { $0.mimeType == "text/calendar" && $0.stubSize == nil }
            ?? root.leaves.first { ($0.filename ?? "").lowercased().hasSuffix(".ics") && $0.stubSize == nil }
        return part.flatMap { CalendarInvite(ics: $0.text) }
    }
}
