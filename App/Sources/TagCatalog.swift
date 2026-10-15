import AppKit
import MailmuleKit
import Observation
import SwiftUI

/// Finder's tag palette and favourites, the same ones Finder and Pathfinder show.
/// Colors come from Finder (favourites, tags already on files), unless the user picked one in Mailmule.
@MainActor
@Observable
final class TagCatalog {
    /// Finder's favourite tags, in Finder's order and language (e.g. "Červená", "Práca").
    private(set) var favorites: [FinderTag] = []
    private var finderColors: [String: Int] = [:]
    private var overrides: [String: Int] = [:]

    init() {
        loadFavorites()
        Task { await loadColorsFromFiles() }
    }

    func color(for name: String) -> Int {
        overrides[name] ?? finderColors[name] ?? 0
    }

    func setOverrides(_ newOverrides: [String: Int]) {
        overrides = newOverrides
        publish()
    }

    /// Tags for menus: Finder's favourites, then other tags in use in mail.
    func menuTags(inUse: [String]) -> [String] {
        let favoriteNames = favorites.map(\.name)
        let known = Set(favoriteNames.map(Tags.fold))
        return favoriteNames + inUse.filter { !known.contains(Tags.fold($0)) }
    }

    private func loadFavorites() {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        var names = (finder?.stringArray(forKey: "FavoriteTagNames") ?? []).filter { !$0.isEmpty }
        if names.isEmpty {
            // Finder never opened: fall back to the color labels in the system language.
            names = Array(NSWorkspace.shared.fileLabels.dropFirst())
        }
        let colors = FinderTagIO.systemColors(for: names)
        finderColors.merge(colors) { _, new in new }
        favorites = names.map { FinderTag(name: $0, color: colors[$0] ?? 0) }
        publish()
    }

    /// Colors of tags already used on files (e.g. "Klienti" set to green in Finder), found via Spotlight.
    private func loadColorsFromFiles() async {
        let found = await Task.detached { () -> [String: Int] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-0", "kMDItemUserTags == '*'"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var colors: [String: Int] = [:]
            for path in data.split(separator: 0).prefix(3000) {
                for tag in FinderTagIO.read(URL(fileURLWithPath: String(decoding: path, as: UTF8.self))) where tag.color != 0 {
                    colors[tag.name] = colors[tag.name] ?? tag.color
                }
            }
            return colors
        }.value
        finderColors.merge(found) { current, _ in current }
        publish()
    }

    /// Hands the effective colors to the vault code, which writes them onto files.
    /// Mailmule-only colors are written as their nearest Finder color.
    private func publish() {
        let effective = finderColors.merging(overrides.mapValues(FinderColor.finderNumber)) { _, override in override }
        FinderTagPalette.shared.update(effective)
    }
}

/// Tag colors: Finder's 7 (numbers 1–7, as stored in Finder tags) plus extra Mailmule colors (101+).
/// Extra colors show exactly in Mailmule; on files Finder gets the nearest of its own colors.
enum FinderColor {
    private struct Extra {
        let name: String
        let color: Color
        let finder: Int
    }

    private static let extras: [Int: Extra] = [
        101: Extra(name: "Tyrkysová", color: .teal, finder: 4),
        102: Extra(name: "Ružová", color: .pink, finder: 6),
        103: Extra(name: "Hnedá", color: .brown, finder: 7),
        104: Extra(name: "Indigo", color: .indigo, finder: 3),
        105: Extra(name: "Mätová", color: .mint, finder: 2),
        106: Extra(name: "Azúrová", color: .cyan, finder: 4),
    ]

    /// Order in pickers: no color, then by hue.
    static let menuOrder = [0, 6, 102, 7, 103, 5, 2, 105, 101, 106, 4, 104, 3, 1]

    /// Whether the color exists in Finder too (Finder can show only 7 colors).
    static func isFinderColor(_ number: Int) -> Bool { number <= 7 }

    static func finderNumber(_ number: Int) -> Int {
        isFinderColor(number) ? number : extras[number]?.finder ?? 0
    }

    static func name(_ number: Int) -> String {
        if number == 0 { return "Bez farby" }
        if let extra = extras[number] { return extra.name }
        let labels = NSWorkspace.shared.fileLabels
        return labels.indices.contains(number) ? labels[number] : "Farba \(number)"
    }

    static func color(_ number: Int) -> Color? {
        if let extra = extras[number] { return extra.color }
        let colors = NSWorkspace.shared.fileLabelColors
        guard number != 0, colors.indices.contains(number) else { return nil }
        return Color(nsColor: colors[number])
    }
}
