import AppKit
import SwiftUI

/// Markdown editor with live styling, like Obsidian's live preview: the text stays Markdown,
/// but bold looks bold, headings are large and syntax markers are dimmed.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var onFiles: ([URL]) -> Void = { _ in }
    var onPastedFile: (String, Data) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = MarkdownStyler.baseFont
        textView.string = text
        textView.onFiles = onFiles
        textView.onPastedFile = onPastedFile
        textView.formatter = controller
        MarkdownStyler.style(textView)
        controller.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.onFiles = onFiles
        textView.onPastedFile = onPastedFile
        if textView.string != text {
            textView.string = text
            MarkdownStyler.style(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MarkdownStyler.style(textView)
            text.wrappedValue = textView.string
        }
    }
}

// MARK: - Text view

final class MarkdownTextView: NSTextView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onPastedFile: (String, Data) -> Void = { _, _ in }
    weak var formatter: MarkdownEditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "b": formatter?.toggleWrap("**")
        case "i": formatter?.toggleWrap("*")
        case "k": formatter?.insertLink()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Continues lists and quotes on Enter; Enter on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: caret.location, length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
        guard let match = MarkdownStyler.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            super.insertNewline(sender)
            return
        }
        let prefix = (line as NSString).substring(with: match.range)
        let content = (line as NSString).substring(from: match.range.length)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: remove the marker instead of adding another one.
            insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
            return
        }
        var next = prefix
        let indent = (line as NSString).substring(with: match.range(at: 1))
        let marker = (line as NSString).substring(with: match.range(at: 2))
        if let number = Int(marker.dropLast()) {
            next = "\(indent)\(number + 1)\(marker.last!) "
        }
        insertText("\n" + next, replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            onPastedFile("Obrázok \(stamp).png", png)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - Formatting commands

/// Formatting actions for the toolbar and shortcuts. They edit the Markdown text through
/// `insertText(_:replacementRange:)` so every change is undoable.
@MainActor
final class MarkdownEditorController {
    weak var textView: MarkdownTextView?

    func focus(atStart: Bool) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if atStart { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    func toggleWrap(_ marker: String) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        let m = (marker as NSString).length

        if range.length == 0 {
            textView.insertText(marker + marker, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + m, length: 0))
            return
        }
        let selected = ns.substring(with: range)
        // Already wrapped just outside the selection: unwrap.
        if range.location >= m, NSMaxRange(range) + m <= ns.length,
           ns.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker {
            textView.insertText(selected, replacementRange: NSRange(location: range.location - m, length: range.length + 2 * m))
            textView.setSelectedRange(NSRange(location: range.location - m, length: range.length))
            return
        }
        // Selection includes the markers: unwrap.
        if selected.hasPrefix(marker), selected.hasSuffix(marker), range.length >= 2 * m {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: range.length - 2 * m))
            textView.insertText(inner, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
            return
        }
        textView.insertText(marker + selected + marker, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + m, length: range.length))
    }

    enum LinePrefix {
        case heading, bullet, numbered, quote

        var pattern: String {
            switch self {
            case .heading: #"^#{1,6} "#
            case .bullet: #"^\s*[-*+] "#
            case .numbered: #"^\s*\d+[.)] "#
            case .quote: #"^> ?"#
            }
        }

        func prefix(index: Int) -> String {
            switch self {
            case .heading: "## "
            case .bullet: "- "
            case .numbered: "\(index + 1). "
            case .quote: "> "
            }
        }
    }

    /// Adds the prefix to every selected line, or removes it when all lines already have it.
    func toggleLinePrefix(_ kind: LinePrefix) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        var block = ns.substring(with: lineRange)
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let regex = try! NSRegularExpression(pattern: kind.pattern)
        let hasPrefix = { (line: String) in
            regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !nonEmpty.isEmpty && nonEmpty.allSatisfy(hasPrefix)

        var index = 0
        let updated = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
            if remove {
                return regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            }
            defer { index += 1 }
            return kind.prefix(index: index) + line
        }
        let replacement = updated.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        textView.insertText(replacement, replacementRange: lineRange)
        let length = (replacement as NSString).length - (trailingNewline ? 1 : 0)
        textView.setSelectedRange(NSRange(location: lineRange.location + length, length: 0))
    }

    /// Wraps the selection as `[text](url)`, using a URL from the clipboard when there is one.
    func insertLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = clipboard.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil } ?? "https://"
        let label = selected.isEmpty ? "odkaz" : selected
        let markdown = "[\(label)](\(url))"
        textView.insertText(markdown, replacementRange: range)
        let urlStart = range.location + (label as NSString).length + 3
        if url == "https://" {
            textView.setSelectedRange(NSRange(location: urlStart, length: (url as NSString).length))
        } else if selected.isEmpty {
            textView.setSelectedRange(NSRange(location: range.location + 1, length: (label as NSString).length))
        } else {
            textView.setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
        }
    }
}

// MARK: - Styling

@MainActor
enum MarkdownStyler {
    /// Editor text size (Nastavenia → Písanie).
    static var baseFontSize: CGFloat = 14
    static var baseFont: NSFont { NSFont.systemFont(ofSize: baseFontSize) }
    static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular) }

    static let listPrefix = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)]|>)\s"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6}) .*$"#, options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: #"^>.*$"#, options: .anchorsMatchLines)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^> ?"#, options: .anchorsMatchLines)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+[.)]) "#, options: .anchorsMatchLines)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    static func style(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 2

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)

        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor]

        for match in heading.matches(in: storage.string, range: full) {
            let level = match.range(at: 1).length
            let size: CGFloat = [24, 20, 17, 15, 14, 14][level - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: match.range)
            storage.addAttributes(dim, range: NSRange(location: match.range.location, length: level + 1))
        }

        for match in quote.matches(in: storage.string, range: full) {
            let quoteParagraph = NSMutableParagraphStyle()
            quoteParagraph.lineSpacing = 3
            quoteParagraph.headIndent = 14
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quoteParagraph], range: match.range)
        }
        for match in quoteMarker.matches(in: storage.string, range: full) {
            storage.addAttributes([.foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.6)], range: match.range)
        }

        for match in listMarker.matches(in: storage.string, range: full) {
            storage.addAttributes([.foregroundColor: NSColor.controlAccentColor], range: match.range(at: 1))
        }

        for match in bold.matches(in: storage.string, range: full) {
            addTrait(.boldFontMask, to: storage, range: match.range)
            let m = match.range(at: 1).length
            storage.addAttributes(dim, range: NSRange(location: match.range.location, length: m))
            storage.addAttributes(dim, range: NSRange(location: NSMaxRange(match.range) - m, length: m))
        }

        for match in italic.matches(in: storage.string, range: full) {
            addTrait(.italicFontMask, to: storage, range: match.range)
            storage.addAttributes(dim, range: NSRange(location: match.range.location, length: 1))
            storage.addAttributes(dim, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }

        for match in strike.matches(in: storage.string, range: full) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            storage.addAttributes(dim, range: NSRange(location: match.range.location, length: 2))
            storage.addAttributes(dim, range: NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }

        for match in code.matches(in: storage.string, range: full) {
            storage.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor], range: match.range)
        }

        for match in link.matches(in: storage.string, range: full) {
            storage.addAttributes(dim, range: match.range)
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                                  range: match.range(at: 1))
        }
        storage.endEditing()

        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }
}
