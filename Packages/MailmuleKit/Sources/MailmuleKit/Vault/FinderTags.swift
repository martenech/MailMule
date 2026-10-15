import Foundation

/// A macOS Finder tag: a name plus Finder's color number (0 none, 1 gray, 2 green, 3 purple, 4 blue,
/// 5 yellow, 6 red, 7 orange). Same model as Pathfinder, so tags look the same in Finder,
/// Pathfinder and Mailmule.
public struct FinderTag: Hashable, Codable, Identifiable, Sendable {
    public let name: String
    public let color: Int

    public var id: String { name }

    public init(name: String, color: Int) {
        self.name = name
        self.color = color
    }
}

/// Reads and writes Finder tags on files (the `_kMDItemUserTags` extended attribute, exactly as Finder writes it).
public enum FinderTagIO {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func read(_ url: URL) -> [FinderTag] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size,
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return entries.map(parse)
    }

    static func parse(_ entry: String) -> FinderTag {
        let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let color = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        return FinderTag(name: String(parts[0]), color: color)
    }

    public static func write(_ tags: [FinderTag], to url: URL) throws {
        if tags.isEmpty {
            if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let entries = tags.map { "\($0.name)\n\($0.color)" }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Colors the system gives tag names (it knows the localized standard names, e.g. "Červená" → red).
    /// Asks Foundation by tagging a scratch file, so it works in every language.
    public static func systemColors(for names: [String]) -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mailmule-tags-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: scratch.path, contents: Data()) else { return [:] }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? (scratch as NSURL).setResourceValue(names, forKey: .tagNamesKey)) != nil else { return [:] }
        return Dictionary(read(scratch).map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Tag colors shared between the app (which learns them from Finder and the user) and the vault code
/// (which writes Finder tags onto thread notes and exported files).
public final class FinderTagPalette: @unchecked Sendable {
    public static let shared = FinderTagPalette()

    private let lock = NSLock()
    private var colors: [String: Int] = [:]

    public func color(for name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return colors[name] ?? 0
    }

    public func update(_ newColors: [String: Int]) {
        lock.lock()
        colors = newColors
        lock.unlock()
    }

    public func tags(_ names: [String]) -> [FinderTag] {
        names.filter(Tags.isUserTag).map { FinderTag(name: $0, color: color(for: $0)) }
    }

    /// Puts the given tags on a file; failures (e.g. a file system without xattrs) are ignored.
    public func apply(_ names: [String], to url: URL) {
        try? FinderTagIO.write(tags(names), to: url)
    }
}
