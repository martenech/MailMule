import Foundation

/// A thread prepared for export: its messages plus the attachment files from the raw messages.
public struct ExportedThread: Sendable {
    public struct File: Sendable {
        public let messageKey: String
        public let filename: String
        public let mimeType: String
        public let data: Data
    }

    public let filename: String
    public let messages: [StoredMessage]
    public let ownAddresses: Set<String>
    public let attachments: [File]
}

/// Copies thread notes from the mail vault into an Obsidian vault.
public struct ObsidianExporter: Sendable {
    public let vaultURL: URL
    public let folder: String

    public init(vaultURL: URL, folder: String) {
        self.vaultURL = vaultURL
        self.folder = folder
    }

    public var folderURL: URL {
        folder.isEmpty ? vaultURL : vaultURL.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Writes the note and returns its file URL. An existing note for the same thread is overwritten.
    @discardableResult
    public func export(markdown: String, filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appending(path: filename)
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Exports a thread with its attachments: files go to `<folder>/Prílohy/<note name>/`
    /// and the note embeds them with Obsidian links.
    @discardableResult
    public func export(thread: ExportedThread) throws -> URL {
        let noteName = (thread.filename as NSString).deletingPathExtension
        let attachmentsFolder = folderURL.appending(path: "Prílohy/\(noteName)", directoryHint: .isDirectory)
        // Replace whatever an earlier export of this thread left behind.
        try? FileManager.default.removeItem(at: attachmentsFolder)

        var links: [String: [String]] = [:]
        if !thread.attachments.isEmpty {
            try FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        }
        var used = Set<String>()
        var seenTags = Set<String>()
        let tags = thread.messages.flatMap(\.labels).filter(Tags.isUserTag).filter { seenTags.insert($0).inserted }
        for attachment in thread.attachments {
            // Characters that would break an Obsidian [[link]].
            let cleaned = DraftStore.safeFilename(attachment.filename).components(separatedBy: CharacterSet(charactersIn: "[]#|^")).joined()
            let name = Self.uniqueName(cleaned, used: &used)
            let fileURL = attachmentsFolder.appending(path: name)
            try attachment.data.write(to: fileURL, options: .atomic)
            FinderTagPalette.shared.apply(tags, to: fileURL)
            let vaultPath = [folder, "Prílohy", noteName, name].filter { !$0.isEmpty }.joined(separator: "/")
            links[attachment.messageKey, default: []].append(Self.link(vaultPath, mimeType: attachment.mimeType))
        }
        let markdown = ThreadMarkdown.render(messages: thread.messages, ownAddresses: thread.ownAddresses, attachmentLinks: links)
        let url = try export(markdown: markdown, filename: thread.filename)
        FinderTagPalette.shared.apply(tags, to: url)
        return url
    }

    /// Images and PDFs are embedded (`![[…]]`), other files linked (`[[…]]`).
    static func link(_ path: String, mimeType: String) -> String {
        let embed = mimeType.hasPrefix("image/") || mimeType == "application/pdf"
            || mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/")
        return embed ? "![[\(path)]]" : "- [[\(path)]]"
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// `obsidian://open?path=...` opens the note in Obsidian.
    public static func openURL(for fileURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        return components.url
    }
}
