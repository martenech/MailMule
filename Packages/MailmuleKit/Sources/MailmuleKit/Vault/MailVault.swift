import Foundation

/// The mail vault: a plain folder you own.
///
///     ~/Mail/
///     ├── .mailmule/index.sqlite    (cache, can be deleted)
///     ├── accounts/<id>/raw/*.eml   (original messages)
///     └── threads/*.md              (one Markdown file per thread)
public struct MailVault: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var indexURL: URL { root.appending(path: ".mailmule/index.sqlite") }
    public var threadsURL: URL { root.appending(path: "threads", directoryHint: .isDirectory) }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: threadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".mailmule"), withIntermediateDirectories: true)
    }

    public func rawRelativePath(account: String, key: String) -> String {
        "accounts/\(account)/raw/\(key).eml"
    }

    public func rawExists(account: String, key: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: rawRelativePath(account: account, key: key)).path)
    }

    @discardableResult
    public func storeRaw(_ data: Data, account: String, key: String) throws -> String {
        let relative = rawRelativePath(account: account, key: key)
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return relative
    }

    /// Removes all stored `.eml` files (after the index was reset); they are downloaded again on sync.
    public func removeAllRaw() {
        let accounts = root.appending(path: "accounts", directoryHint: .isDirectory)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: accounts.path)) ?? []
        for id in ids {
            try? FileManager.default.removeItem(at: accounts.appending(path: "\(id)/raw"))
        }
    }

    /// Deletes an account's stored messages and the given thread notes.
    public func removeAccountFiles(_ account: String, notes: [String]) {
        try? FileManager.default.removeItem(at: root.appending(path: "accounts/\(account)", directoryHint: .isDirectory))
        for note in notes { try? FileManager.default.removeItem(at: threadURL(filename: note)) }
    }

    public func readRaw(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appending(path: relativePath))
    }

    public func threadURL(filename: String) -> URL {
        threadsURL.appending(path: filename)
    }

    public func writeThread(_ markdown: String, filename: String) throws {
        try Data(markdown.utf8).write(to: threadURL(filename: filename), options: .atomic)
    }
}
