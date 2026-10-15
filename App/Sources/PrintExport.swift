import AppKit
import MailmuleKit
import PDFKit
import WebKit

/// Turns the printable HTML of a thread into a paginated A4 PDF. WebKit renders the page as PDF
/// (`createPDF`), and the pages are cut between lines of text so no line is split.
@MainActor
final class ThreadPDF: NSObject, WKNavigationDelegate {
    static let pageSize = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 36
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?

    static func make(html: String) async throws -> Data {
        try await ThreadPDF().render(html)
    }

    private func render(_ html: String) async throws -> Data {
        let width = Self.pageSize.width - 2 * Self.margin
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        try? await Task.sleep(for: .milliseconds(200))

        // Content height and the vertical extent of every line of text (and small images), to break between them.
        let script = """
        (function(){var r=[],w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),n,range=document.createRange();
        while(n=w.nextNode()){if(!n.textContent.trim())continue;range.selectNodeContents(n);var rs=range.getClientRects();
        for(var i=0;i<rs.length;i++)r.push([rs[i].top+scrollY,rs[i].bottom+scrollY]);}
        for(var j=0;j<document.images.length;j++){var b=document.images[j].getBoundingClientRect();if(b.height<400)r.push([b.top+scrollY,b.bottom+scrollY]);}
        return JSON.stringify({h:Math.max(document.body.scrollHeight,document.documentElement.scrollHeight),w:Math.max(document.body.scrollWidth,document.documentElement.scrollWidth),r:r});})()
        """
        struct Layout: Decodable { let h: Double; let w: Double; let r: [[Double]] }
        func measure() async throws -> Layout {
            let json = try await webView.evaluateJavaScript(script) as? String ?? "{}"
            return try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        }
        var layout = try await measure()
        // Mails wider than the page (fixed 600–700 px newsletters) are laid out at their width and scaled down.
        var contentWidth = width
        if CGFloat(layout.w) > width + 1 {
            contentWidth = min(CGFloat(layout.w), 1400)
            webView.frame.size.width = contentWidth
            try? await Task.sleep(for: .milliseconds(150))
            layout = try await measure()
        }
        let scale = width / contentWidth
        let height = CGFloat(layout.h)
        webView.frame.size.height = max(height, 1000)

        let pageHeight = (Self.pageSize.height - 2 * Self.margin) / scale
        let lines = layout.r.filter { $0.count == 2 }.map { (CGFloat($0[0]), CGFloat($0[1])) }
        var slices: [ClosedRange<CGFloat>] = []
        var top: CGFloat = 0
        while top < height - 1 {
            var bottom = min(top + pageHeight, height)
            if bottom < height {
                // Move the cut up above any line it would split (but never below half a page).
                var moved = true
                while moved {
                    moved = false
                    for line in lines where line.0 < bottom && line.1 > bottom && line.0 > top {
                        bottom = line.0
                        moved = true
                    }
                }
                if bottom - top < pageHeight / 2 { bottom = top + pageHeight }
            }
            slices.append(top...bottom)
            top = bottom
        }

        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw CocoaError(.fileWriteUnknown) }
        for slice in slices {
            let pdfConfiguration = WKPDFConfiguration()
            pdfConfiguration.rect = CGRect(x: 0, y: slice.lowerBound, width: contentWidth, height: slice.upperBound - slice.lowerBound)
            let data = try await webView.pdf(configuration: pdfConfiguration)
            guard let page = CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: 1) else { continue }
            context.beginPDFPage(nil)
            let box = page.getBoxRect(.mediaBox)
            // Top-aligned inside the margins, scaled to the page width.
            context.translateBy(x: Self.margin, y: Self.pageSize.height - Self.margin - box.height * scale)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        self.webView = nil
        return output as Data
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }
}

extension AppModel {
    /// The selected thread as one printable HTML document.
    func printableHTML() -> (html: String, title: String)? {
        guard !messages.isEmpty else { return nil }
        let subject = messages.last?.subject ?? ""
        let title = subject.isEmpty ? "(bez predmetu)" : subject
        var parts: [String] = []
        for message in messages {
            let from = message.from.map { address in
                address.name.map { "\(Self.escape($0)) &lt;\(Self.escape(address.address))&gt;" } ?? Self.escape(address.address)
            } ?? ""
            var rows = ["<tr><th>Od</th><td>\(from)</td></tr>"]
            if !message.to.isEmpty { rows.append("<tr><th>Komu</th><td>\(Self.addressList(message.to))</td></tr>") }
            if !message.cc.isEmpty { rows.append("<tr><th>Kópia</th><td>\(Self.addressList(message.cc))</td></tr>") }
            rows.append("<tr><th>Dátum</th><td>\(message.date.formatted(date: .long, time: .shortened))</td></tr>")
            let attachments = attachmentInfo(for: message)
            if !attachments.isEmpty {
                let names = attachments.map { "\(Self.escape($0.filename)) (\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)))" }
                rows.append("<tr><th>Prílohy</th><td>\(names.joined(separator: ", "))</td></tr>")
            }
            var body: String
            if message.hasHTML, let display = displayHTML(for: message) {
                body = Self.innerBody(display.html)
                if !remoteImagesAllowed(for: message) { body = Self.withoutRemoteImages(body) }
                else if settings.blockTrackers { body = TrackerFilter.strip(body).html }
            } else {
                body = "<div class=\"plain\">\(Self.escape(mime(for: message)?.bestText ?? message.bodyText))</div>"
            }
            parts.append("""
            <section class="message">
              <table class="headers">\(rows.joined())</table>
              <div class="body">\(body)</div>
            </section>
            """)
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">
        <title>\(Self.escape(title))</title>
        <style>
          body { font: 11pt -apple-system, Helvetica, sans-serif; color: #1d1d1f; margin: 0; background: #fff; }
          /* Mails bring their own CSS (dark backgrounds, fonts); keep our title and headers readable. */
          h1.mm-title { font: 600 17pt -apple-system, Helvetica, sans-serif !important; color: #1d1d1f !important; margin: 0 0 4pt !important; background: #fff !important; }
          .meta { color: #6e6e73 !important; font: 9pt -apple-system, Helvetica, sans-serif !important; margin-bottom: 14pt; background: #fff !important; }
          .message > table.headers { background: #fff !important; }
          html, body, .message { background: #fff !important; }
          .message { border-top: 1px solid #d2d2d7 !important; }
          .message { border-top: 1px solid #d2d2d7; padding-top: 10pt; margin-top: 14pt; }
          .message:first-of-type { margin-top: 0; }
          /* The mail's own CSS is printed too; keep it off our header table. */
          table.headers { font-size: 9.5pt !important; border-collapse: collapse !important; border: none !important; margin: 0 0 10pt !important; width: auto !important; }
          table.headers th, table.headers td { border: none !important; background: none !important; font-family: -apple-system, Helvetica, sans-serif !important; }
          table.headers th { text-align: left !important; color: #6e6e73 !important; font-weight: 500 !important; padding: 1pt 10pt 1pt 0 !important; vertical-align: top; white-space: nowrap; }
          table.headers td { padding: 1pt 0 !important; color: #1d1d1f !important; }
          .body { overflow-wrap: anywhere; }
          .body img { max-width: 100%; height: auto; }
          .plain { white-space: pre-wrap; }
          blockquote { border-left: 2px solid #d2d2d7; margin-left: 0; padding-left: 10pt; color: #515154; }
        </style></head><body>
        <h1 class="mm-title">\(Self.escape(title))</h1>
        <div class="meta">\(messages.count) \(messages.count == 1 ? "správa" : messages.count < 5 ? "správy" : "správ") · vytlačené z Mailmule \(Date().formatted(date: .abbreviated, time: .shortened))</div>
        \(parts.joined(separator: "\n"))
        </body></html>
        """
        return (html, title)
    }

    func printSelectedThread() {
        guard let (html, title) = printableHTML() else { return }
        Task {
            do {
                let data = try await ThreadPDF.make(html: html)
                guard let document = PDFDocument(data: data) else { return }
                let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
                guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false) else { return }
                operation.jobTitle = title
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                } else {
                    operation.run()
                }
            } catch {
                errorMessage = "Vlákno sa nepodarilo pripraviť na tlač: \(error.localizedDescription)"
            }
        }
    }

    func exportSelectedThreadAsPDF() {
        guard let (html, title) = printableHTML() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.safeFilename(title) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await saveThreadPDF(html: html, to: url, reveal: true) }
    }

    func saveThreadPDF(html: String, to url: URL, reveal: Bool) async {
        do {
            try await ThreadPDF.make(html: html).write(to: url)
            showToast("PDF uložené")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            log("pdf: \(url.lastPathComponent)")
        } catch {
            errorMessage = "PDF sa nepodarilo uložiť: \(error.localizedDescription)"
        }
    }

    static func safeFilename(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Vlákno" : String(cleaned.prefix(120))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func addressList(_ list: [EmailAddress]) -> String {
        list.map { address in
            address.name.map { "\(escape($0)) &lt;\(escape(address.address))&gt;" } ?? escape(address.address)
        }.joined(separator: ", ")
    }

    /// The content of a full HTML document's <body> (its <style> blocks kept), for placing inside a section.
    static func innerBody(_ html: String) -> String {
        let styles = html.matches(of: /(?is)<style\b[^>]*>.*?<\/style>/).map { String($0.output) }.joined()
        if let body = html.firstMatch(of: /(?is)<body\b[^>]*>(.*)<\/body>/) {
            return styles + String(body.output.1)
        }
        return html
    }

    /// Images from the internet left out, as in the reading view when they are blocked.
    static func withoutRemoteImages(_ html: String) -> String {
        html.replacing(/(?i)<img\b[^>]*\bsrc\s*=\s*["']?\s*(https?:)?\/\/[^>]*>/, with: "")
    }
}
