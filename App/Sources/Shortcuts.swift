import Foundation

/// Single-key commands (Superhuman/Gmail style) that work when no text field is focused.
/// Each has default keys; Settings → Skratky can assign another key or turn one off.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case next, previous, search, preview
    case compose, reply, replyAll, forward
    case archive, delete, toInbox, move, tag, snooze, star, read, obsidian, undo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .next: "Ďalšie vlákno"
        case .previous: "Predchádzajúce vlákno"
        case .search: "Hľadať"
        case .preview: "Náhľad príloh (Quick Look)"
        case .compose: "Nová správa"
        case .reply: "Odpovedať"
        case .replyAll: "Odpovedať všetkým"
        case .forward: "Preposlať"
        case .archive: "Archivovať"
        case .delete: "Odstrániť"
        case .toInbox: "Presunúť do Doručenej"
        case .move: "Presunúť do priečinka"
        case .tag: "Štítok"
        case .snooze: "Odložiť"
        case .star: "Hviezdička"
        case .read: "Prečítané / neprečítané"
        case .obsidian: "Uložiť do Obsidianu"
        case .undo: "Vrátiť poslednú akciu"
        }
    }

    enum Group: String, CaseIterable {
        case navigation = "Navigácia"
        case writing = "Písanie"
        case thread = "Práca s vláknom"
    }

    var group: Group {
        switch self {
        case .next, .previous, .search, .preview: .navigation
        case .compose, .reply, .replyAll, .forward: .writing
        default: .thread
        }
    }

    /// Keys as delivered by `KeyMonitor` (lowercased characters; "\u{7f}" is ⌫, "\u{f728}" ⌦).
    var defaultKeys: [String] {
        switch self {
        case .next: ["j"]
        case .previous: ["k"]
        case .search: ["/"]
        case .preview: [" "]
        case .compose: ["c"]
        case .reply: ["r"]
        case .replyAll: ["a"]
        case .forward: ["f"]
        case .archive: ["e"]
        case .delete: ["#", "\u{7f}", "\u{f728}"]
        case .toInbox: ["i"]
        case .move: ["v"]
        case .tag: ["l"]
        case .snooze: ["h"]
        case .star: ["s"]
        case .read: ["u"]
        case .obsidian: ["o"]
        case .undo: ["z"]
        }
    }

    /// The keys in effect: the user's choice ("" turns the shortcut off) or the defaults.
    func keys(_ overrides: [String: String]) -> [String] {
        guard let custom = overrides[rawValue] else { return defaultKeys }
        return custom.isEmpty ? [] : [custom]
    }

    static func action(for key: String, overrides: [String: String]) -> ShortcutAction? {
        allCases.first { $0.keys(overrides).contains(key) }
    }

    /// How a key is shown on a keycap.
    static func label(_ key: String) -> String {
        switch key {
        case " ": "␣"
        case "\u{7f}": "⌫"
        case "\u{f728}": "⌦"
        case "\u{1b}": "Esc"
        case "\t": "⇥"
        case "\r": "↩"
        default: key.uppercased()
        }
    }
}

extension AppModel {
    /// " (e)" for tooltips, or nothing when the shortcut is off.
    func shortcutHint(_ action: ShortcutAction) -> String {
        guard let key = action.keys(settings.shortcuts).first else { return "" }
        return " (\(ShortcutAction.label(key)))"
    }

    /// "j / k pohyb · e archivovať · …" for the empty thread pane, with the user's keys.
    var shortcutOverview: String {
        let key = { (action: ShortcutAction) in self.shortcutKey(action).lowercased() }
        var parts: [String] = []
        if !key(.next).isEmpty || !key(.previous).isEmpty { parts.append("\(key(.next)) / \(key(.previous)) pohyb") }
        let items: [(ShortcutAction, String)] = [(.archive, "archivovať"), (.delete, "zmazať"), (.star, "hviezdička"), (.tag, "štítok"),
                                                 (.move, "presunúť"), (.reply, "odpovedať"), (.forward, "preposlať"), (.obsidian, "do Obsidianu")]
        parts += items.compactMap { action, title in key(action).isEmpty ? nil : "\(key(action)) \(title)" }
        parts.append("⌘K príkazy")
        return parts.joined(separator: " · ")
    }

    /// The key shown in the command palette ("" when off).
    func shortcutKey(_ action: ShortcutAction) -> String {
        action.keys(settings.shortcuts).first.map(ShortcutAction.label) ?? ""
    }

    func perform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .next: moveSelection(1)
        case .previous: moveSelection(-1)
        case .search: searchFocusRequest += 1
        case .preview: return previewSelectedAttachments()
        case .compose: composeNew()
        case .reply: reply(all: false)
        case .replyAll: reply(all: true)
        case .forward: forward()
        case .archive: archiveSelected()
        case .delete: deleteSelected()
        case .toInbox: moveSelectedToInbox()
        case .move: openFolderPicker()
        case .tag: openTagPicker()
        case .snooze: openSnoozePicker()
        case .star: toggleStar()
        case .read: toggleRead()
        case .obsidian: exportSelectedToObsidian()
        case .undo: undoLast()
        }
        return true
    }
}
