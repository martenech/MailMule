import Foundation

/// How a newsletter can be left, from List-Unsubscribe (RFC 2369) and List-Unsubscribe-Post (RFC 8058).
public struct UnsubscribeInfo: Equatable, Sendable {
    public var web: URL?
    public var mailto: (address: String, subject: String, body: String)?
    /// The web link accepts a POST "List-Unsubscribe=One-Click": no page to open, nothing to confirm.
    public var oneClick = false

    public enum Method: Equatable, Sendable {
        case oneClick(URL)
        case email(address: String, subject: String, body: String)
        case website(URL)
    }

    /// The best way: one-click, then an e-mail, then the web page.
    public var preferred: Method? {
        if oneClick, let web { return .oneClick(web) }
        if let mailto { return .email(address: mailto.address, subject: mailto.subject, body: mailto.body) }
        if let web { return .website(web) }
        return nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.web == rhs.web && lhs.oneClick == rhs.oneClick
            && lhs.mailto?.address == rhs.mailto?.address && lhs.mailto?.subject == rhs.mailto?.subject
    }

    public init?(headers: MIMEHeaders) {
        guard let raw = headers["List-Unsubscribe"] else { return nil }
        // "<mailto:x@y?subject=unsubscribe>, <https://example.com/u/123>"
        let unfolded = raw.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
        var links: [String] = []
        var current: String?
        for character in unfolded {
            if character == "<" { current = "" }
            else if character == ">" { if let link = current { links.append(link.trimmingCharacters(in: .whitespaces)) }; current = nil }
            else if current != nil { current?.append(character) }
        }
        for link in links {
            let lower = link.lowercased()
            if lower.hasPrefix("https://") || lower.hasPrefix("http://"), web == nil, let url = URL(string: link) {
                web = url
            } else if lower.hasPrefix("mailto:"), mailto == nil, let parsed = Self.mailto(link) {
                mailto = parsed
            }
        }
        oneClick = (headers["List-Unsubscribe-Post"] ?? "").lowercased().contains("one-click") && web?.scheme == "https"
        guard web != nil || mailto != nil else { return nil }
    }

    static func mailto(_ link: String) -> (address: String, subject: String, body: String)? {
        let rest = link.dropFirst("mailto:".count)
        let parts = rest.split(separator: "?", maxSplits: 1).map(String.init)
        guard let address = parts.first?.removingPercentEncoding, address.contains("@") else { return nil }
        var subject = "unsubscribe"
        var body = ""
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let value = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
                switch kv[0].lowercased() {
                case "subject": subject = value
                case "body": body = value
                default: break
                }
            }
        }
        return (address, subject, body)
    }

    /// RFC 8058: POST with the form field and no cookies or redirects to the user's session.
    public static func oneClickRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.httpShouldHandleCookies = false
        return request
    }
}

extension MIMEMessage {
    public var unsubscribe: UnsubscribeInfo? { UnsubscribeInfo(headers: headers) }
}
