import Foundation

/// Renders a thread as a Markdown note with YAML frontmatter, in the style of an Obsidian note.
public enum ThreadMarkdown {
    /// `attachmentLinks` maps a message key to Obsidian links for its saved attachments;
    /// messages without an entry list attachment names only.
    public static func render(messages: [StoredMessage], ownAddresses: Set<String>, tags: [String] = [],
                              attachmentLinks: [String: [String]] = [:]) -> String {
        guard let first = messages.first, let last = messages.last else { return "" }
        let ownAddresses = Set(ownAddresses.map { $0.lowercased() })

        var people: [String] = []
        for message in messages {
            for address in [message.from].compactMap({ $0 }) + message.to + message.cc
            where !ownAddresses.contains(address.address.lowercased()) {
                let link = "[[\(noteName(address))]]"
                if !people.contains(link) { people.append(link) }
            }
        }

        let labels = Set(messages.flatMap(\.labels)).map(tagName).filter { !$0.isEmpty }
        let allTags = Array(Set(tags + labels)).sorted()

        var lines = ["---"]
        lines.append("subject: \(yaml(last.subject.baseSubject))")
        lines.append("date: \(isoDay(first.date))")
        lines.append("updated: \(isoDay(last.date))")
        lines.append("people:")
        lines += people.map { "  - \(yaml($0))" }
        lines.append("tags:")
        lines += allTags.map { "  - \($0)" }
        lines.append("mailmule: \(yaml(link(threadID: first.threadID)))")
        lines.append("---")
        lines.append("")
        lines.append("# \(last.subject.baseSubject.isEmpty ? "(bez predmetu)" : last.subject.baseSubject)")
        lines.append("")

        for message in messages {
            let sender = message.from.map { address in
                ownAddresses.contains(address.address.lowercased()) ? "Ja" : "[[\(noteName(address))]]"
            } ?? "Neznámy odosielateľ"
            lines.append("## \(sender) · \(displayDate(message.date))")
            lines.append("")
            lines.append(stripQuotedReply(message.bodyText))
            if let links = attachmentLinks[message.key], !links.isEmpty {
                lines.append("")
                lines.append("Prílohy:")
                lines.append("")
                lines += links
            } else if !message.attachments.isEmpty {
                lines.append("")
                lines.append("Prílohy: " + message.attachments.map { "`\($0)`" }.joined(separator: ", "))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func link(threadID: String) -> String {
        "mailmule://thread/" + (threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? threadID)
    }

    /// `2026-10-13 Faktúra za september.md`
    public static func filename(subject: String, date: Date, suffix: String? = nil) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        var cleaned = subject.baseSubject.components(separatedBy: forbidden).joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "bez predmetu" }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        let suffixPart = suffix.map { " (\($0))" } ?? ""
        return "\(isoDay(date)) \(cleaned)\(suffixPart).md"
    }

    /// Name of the person note in Obsidian: display name, or the address when there is none.
    public static func noteName(_ address: EmailAddress) -> String {
        let forbidden = CharacterSet(charactersIn: "[]|#^\\/:")
        return address.displayName.components(separatedBy: forbidden).joined().trimmingCharacters(in: .whitespaces)
    }

    /// Removes the trailing quoted original ("> ..." lines and the "On ... wrote:" line before them).
    public static func stripQuotedReply(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix(">") {
            lines.removeLast()
        }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces),
           last.hasSuffix("wrote:") || last.hasSuffix("napísal:") || last.hasSuffix("napísal(a):")
            || last.hasSuffix("napsal:") || last.hasSuffix("napsal(a):") || last.hasSuffix("schrieb:") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tagName(_ label: String) -> String {
        let lowered = label.lowercased()
        // Gmail system labels are noise in a note.
        if lowered.hasPrefix("\\") { return "" }
        return label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "[^\\p{L}\\p{N}_/-]", with: "", options: .regularExpression)
    }

    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy HH:mm"
        return formatter.string(from: date)
    }
}
