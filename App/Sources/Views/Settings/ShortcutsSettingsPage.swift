import AppKit
import SwiftUI

/// Single-key shortcuts can be changed (press the new key), turned off or reset; ⌘ menu commands are fixed.
struct ShortcutsSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var notice: String?

    /// Menu commands with ⌘; shown for reference.
    private static let menuShortcuts: [(String, [String])] = [
        ("Paleta príkazov", ["⌘", "K"]),
        ("Nová správa", ["⌘", "N"]),
        ("Synchronizovať", ["⌘", "R"]),
        ("Doručená pošta / Odoslané / Archív / Kôš / Všetka pošta", ["⌘", "1–5"]),
        ("Koncepty", ["⇧", "⌘", "D"]),
        ("Odoslať", ["⌘", "↩"]),
        ("Priložiť súbor", ["⇧", "⌘", "A"]),
        ("Náhľad správy", ["⇧", "⌘", "P"]),
        ("Tučné / kurzíva / odkaz", ["⌘", "B · I · K"]),
        ("Vrátiť poslednú akciu", ["⌘", "Z"]),
    ]

    var body: some View {
        SettingsPage(category: .shortcuts) {
            HStack {
                TextField("Hľadať skratku…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                Button("Obnoviť predvolené") {
                    model.settings.shortcuts = [:]
                    notice = "Všetky skratky sú zase predvolené."
                }
                .disabled(model.settings.shortcuts.isEmpty)
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                let actions = ShortcutAction.allCases.filter { $0.group == group && matches($0.title) }
                if !actions.isEmpty {
                    SettingsCard(group.rawValue) {
                        SettingsRows {
                            ForEach(actions) { action in row(action) }
                        }
                    }
                }
            }
            let menu = Self.menuShortcuts.filter { matches($0.0) }
            if !menu.isEmpty {
                SettingsCard("Príkazy v menu", subtitle: "Skratky s ⌘ sú pevné, ako v ostatných aplikáciách.") {
                    SettingsRows {
                        ForEach(menu, id: \.0) { title, keys in
                            SettingsRow(title) {
                                HStack(spacing: 4) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
                            }
                        }
                    }
                }
            }
            Text("Jednoklávesové skratky fungujú, keď nepíšete do textového poľa. Zmeniť: kliknite na skratku a stlačte novú klávesu (Esc zruší).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let keys = action.keys(model.settings.shortcuts)
        let changed = model.settings.shortcuts[action.rawValue] != nil
        return SettingsRow(action.title) {
            HStack(spacing: 6) {
                Button { startRecording(action) } label: {
                    HStack(spacing: 4) {
                        if recording == action {
                            Text("Stlačte klávesu…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.themeAccent)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 24)
                                .background(Color.themeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        } else if keys.isEmpty {
                            Text("Vypnuté").font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 8).frame(minHeight: 24)
                        } else {
                            ForEach(keys, id: \.self) { Keycap(label: ShortcutAction.label($0)) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Kliknite a stlačte novú klávesu")
                Menu {
                    Button("Zmeniť…") { startRecording(action) }
                    Button("Vypnúť") { model.settings.shortcuts[action.rawValue] = "" }
                        .disabled(keys.isEmpty)
                    Button("Predvolené (\(action.defaultKeys.map(ShortcutAction.label).joined(separator: ", ")))") {
                        model.settings.shortcuts[action.rawValue] = nil
                    }
                    .disabled(!changed)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 22)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func matches(_ title: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return fold(title).contains(fold(needle))
    }

    // MARK: Recording a new key

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        notice = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = recording else { return event }
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
                notice = "Skratka je jedna klávesa bez ⌘, ⌃ a ⌥."
                return nil
            }
            assign(key, to: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// Gives `key` to `action`; another action using it loses it (and is turned off if that was its only key).
    private func assign(_ key: String, to action: ShortcutAction) {
        var shortcuts = model.settings.shortcuts
        for other in ShortcutAction.allCases where other != action && other.keys(shortcuts).contains(key) {
            let remaining = other.keys(shortcuts).filter { $0 != key }
            shortcuts[other.rawValue] = remaining.first ?? ""
            notice = "Klávesa \(ShortcutAction.label(key)) patrila k „\(other.title)“ – " +
                (remaining.isEmpty ? "tá je teraz vypnutá." : "tá má teraz \(ShortcutAction.label(remaining[0])).")
        }
        // Back to the default key: forget the override.
        shortcuts[action.rawValue] = action.defaultKeys == [key] ? nil : key
        model.settings.shortcuts = shortcuts
    }
}

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
    }
}
