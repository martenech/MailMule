import Foundation
import Markdown
import UniformTypeIdentifiers

/// A file attached to an outgoing message.
public struct OutgoingAttachment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String? = nil, data: Data) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType ?? Self.mimeType(forFilename: filename)
        self.data = data
    }

    public init(contentsOf url: URL) throws {
        self.init(filename: url.lastPathComponent, data: try Data(contentsOf: url))
    }

    public static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// An outgoing message written in Markdown.
public struct Draft: Sendable, Equatable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var subject: String
    public var markdown: String
    public var inReplyTo: String?
    public var references: [String] = []
    public var attachments: [OutgoingAttachment] = []
    /// Send only a text/plain part (no HTML).
    public var plainTextOnly = false
    /// An iCalendar answer to a meeting invitation (METHOD:REPLY), sent as a text/calendar part.
    public var calendarReply: String?

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String, markdown: String, inReplyTo: String? = nil, references: [String] = [],
                attachments: [OutgoingAttachment] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.markdown = markdown
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }

    public var recipients: [EmailAddress] { to + cc + bcc }
}

public enum MarkdownRenderer {
    /// Renders Markdown to an HTML fragment. Single newlines become `<br>` like in a mail client.
    public static func html(from markdown: String) -> String {
        var rewriter = SoftBreakRewriter()
        let document = rewriter.visit(Document(parsing: markdown)) ?? Document(parsing: markdown)
        return HTMLFormatter.format(document)
    }

    /// Full HTML document used for the text/html part and for the compose preview.
    public static func emailDocument(from markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.5; color: #1d1d1f; }
        blockquote { margin: 0 0 0 .8em; padding-left: .8em; border-left: 3px solid #d0d0d5; color: #555; }
        code { font-family: Menlo, monospace; font-size: 13px; background: #f2f2f5; padding: 1px 4px; border-radius: 3px; }
        pre { background: #f2f2f5; padding: 8px 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        table { border-collapse: collapse; } td, th { border: 1px solid #d0d0d5; padding: 4px 8px; }
        </style></head><body>
        \(html(from: markdown))
        </body></html>
        """
    }

    private struct SoftBreakRewriter: MarkupRewriter {
        func visitSoftBreak(_ softBreak: SoftBreak) -> Markup? {
            LineBreak()
        }
    }

    /// Readable plain text for the text/plain part: formatting markers are removed,
    /// links become `text (url)`, lists and quotes keep their `-` and `>`.
    public static func plainText(from markdown: String) -> String {
        let document = Document(parsing: markdown)
        let blocks = document.children.map { block($0) }
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func block(_ markup: Markup, indent: String = "") -> String {
        switch markup {
        case let list as UnorderedList:
            return list.listItems.map { listItem($0, marker: "- ", indent: indent) }.joined(separator: "\n")
        case let list as OrderedList:
            return list.listItems.enumerated().map { offset, item in
                listItem(item, marker: "\(Int(list.startIndex) + offset). ", indent: indent)
            }.joined(separator: "\n")
        case let quote as BlockQuote:
            return quote.children.map { block($0) }.joined(separator: "\n\n")
                .components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        case let code as CodeBlock:
            return code.code.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                .map { "    \($0)" }.joined(separator: "\n")
        case is ThematicBreak:
            return "----------"
        case let html as HTMLBlock:
            return HTMLText.extract(html.rawHTML)
        default:
            return inline(markup)
        }
    }

    private static func listItem(_ item: ListItem, marker: String, indent: String) -> String {
        let childIndent = indent + String(repeating: " ", count: marker.count)
        var lines: [String] = []
        for (index, child) in item.children.enumerated() {
            if child is UnorderedList || child is OrderedList {
                lines.append(block(child, indent: childIndent))
            } else {
                let text = block(child, indent: childIndent).components(separatedBy: "\n")
                    .enumerated().map { $0.offset == 0 && index == 0 ? $0.element : childIndent + $0.element }
                    .joined(separator: "\n")
                lines.append(index == 0 ? indent + marker + text : text)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func inline(_ markup: Markup) -> String {
        switch markup {
        case let text as Markdown.Text:
            return text.string
        case let code as InlineCode:
            return code.code
        case is SoftBreak, is LineBreak:
            return "\n"
        case let link as Markdown.Link:
            let label = link.children.map(inline).joined()
            guard let destination = link.destination, !destination.isEmpty else { return label }
            let bare = destination.replacingOccurrences(of: "mailto:", with: "")
            return label == destination || label == bare ? label : "\(label) (\(bare))"
        case let image as Markdown.Image:
            let alt = image.children.map(inline).joined()
            return image.source.map { "\(alt) (\($0))" } ?? alt
        case let html as InlineHTML:
            return html.rawHTML.hasPrefix("<br") ? "\n" : ""
        default:
            return markup.children.map(inline).joined()
        }
    }
}

public enum MessageBuilder {
    /// Builds an RFC 5322 message: the Markdown source as text/plain and the rendered HTML as text/html
    /// (multipart/alternative), wrapped in multipart/mixed when there are attachments.
    public static func build(_ draft: Draft, date: Date = Date(), messageID: String? = nil) -> (data: Data, messageID: String) {
        let domain = draft.from.address.split(separator: "@").last.map(String.init) ?? "mailmule.local"
        let id = messageID ?? "\(UUID().uuidString.lowercased())@\(domain)"
        let alternative = "mailmule-alt-\(UUID().uuidString)"
        let plain = draft.plainTextOnly
        let mixed = "mailmule-mix-\(UUID().uuidString)"
        let hasAttachments = !draft.attachments.isEmpty

        var headers: [(String, String)] = [
            ("From", draft.from.headerValue),
            ("To", draft.to.map(\.headerValue).joined(separator: ", ")),
        ]
        if !draft.cc.isEmpty { headers.append(("Cc", draft.cc.map(\.headerValue).joined(separator: ", "))) }
        headers += [
            ("Subject", EncodedWord.encode(draft.subject)),
            ("Date", MailDate.format(date)),
            ("Message-ID", "<\(id)>"),
        ]
        if let inReplyTo = draft.inReplyTo { headers.append(("In-Reply-To", "<\(inReplyTo)>")) }
        if !draft.references.isEmpty {
            headers.append(("References", draft.references.map { "<\($0)>" }.joined(separator: "\r\n ")))
        }
        headers += [
            ("MIME-Version", "1.0"),
            ("X-Mailer", "Mailmule"),
            ("Content-Type", hasAttachments
                ? "multipart/mixed; boundary=\"\(mixed)\""
                : plain ? "text/plain; charset=utf-8" : "multipart/alternative; boundary=\"\(alternative)\""),
        ]
        if plain && !hasAttachments { headers.append(("Content-Transfer-Encoding", "base64")) }

        var out = Data()
        func line(_ s: String = "") { out.append(Data((s + "\r\n").utf8)) }

        for (name, value) in headers { line("\(name): \(value)") }
        line()
        if plain {
            if hasAttachments {
                line("--\(mixed)")
                line("Content-Type: text/plain; charset=utf-8")
                line("Content-Transfer-Encoding: base64")
                line()
            }
            out.append(base64Lines(text: MarkdownRenderer.plainText(from: draft.markdown)))
        } else {
            if hasAttachments {
                line("--\(mixed)")
                line("Content-Type: multipart/alternative; boundary=\"\(alternative)\"")
                line()
            }
            line("--\(alternative)")
            line("Content-Type: text/plain; charset=utf-8")
            line("Content-Transfer-Encoding: base64")
            line()
            out.append(base64Lines(text: MarkdownRenderer.plainText(from: draft.markdown)))
            line("--\(alternative)")
            line("Content-Type: text/html; charset=utf-8")
            line("Content-Transfer-Encoding: base64")
            line()
            out.append(base64Lines(text: MarkdownRenderer.emailDocument(from: draft.markdown)))
            if let calendar = draft.calendarReply {
                // Calendars (Gmail, Outlook, Apple) read the answer from this part.
                line("--\(alternative)")
                line("Content-Type: text/calendar; charset=utf-8; method=REPLY")
                line("Content-Transfer-Encoding: base64")
                line()
                out.append(base64Lines(text: calendar))
            }
            line("--\(alternative)--")
        }

        if hasAttachments {
            for attachment in draft.attachments {
                line("--\(mixed)")
                line("Content-Type: \(attachment.mimeType); name=\"\(EncodedWord.encode(attachment.filename))\"")
                line("Content-Disposition: attachment; \(filenameParameter(attachment.filename))")
                line("Content-Transfer-Encoding: base64")
                line()
                out.append(base64Lines(data: attachment.data))
            }
            line("--\(mixed)--")
        }
        return (out, id)
    }

    /// `filename="a.pdf"`, or RFC 2231 `filename*=utf-8''fakt%C3%BAra.pdf` for non-ASCII names.
    static func filenameParameter(_ filename: String) -> String {
        if filename.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\\" }) {
            return "filename=\"\(filename)\""
        }
        let allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
            .union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? filename
        return "filename*=utf-8''\(encoded)"
    }

    static func base64Lines(text: String) -> Data {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return base64Lines(data: Data(normalized.utf8))
    }

    /// Base64 wrapped at 76 characters with CRLF line ends, terminated by CRLF.
    static func base64Lines(data: Data) -> Data {
        var encoded = data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        encoded.append(Data("\r\n".utf8))
        return encoded
    }
}
