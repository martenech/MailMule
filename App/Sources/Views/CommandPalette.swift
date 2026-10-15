import MailmuleKit
import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String
    let action: @MainActor () -> Void
}

/// ⌘K command palette in the style of Superhuman and Obsidian.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [PaletteCommand] {
        var list = [
            PaletteCommand(title: "Nová správa", shortcut: model.shortcutKey(.compose)) { model.composeNew() },
            PaletteCommand(title: "Odpovedať", shortcut: model.shortcutKey(.reply)) { model.reply(all: false) },
            PaletteCommand(title: "Odpovedať všetkým", shortcut: model.shortcutKey(.replyAll)) { model.reply(all: true) },
            PaletteCommand(title: "Preposlať", shortcut: model.shortcutKey(.forward)) { model.forward() },
            PaletteCommand(title: "Archivovať vlákno", shortcut: model.shortcutKey(.archive)) { model.archiveSelected() },
            PaletteCommand(title: "Zmazať vlákno (do koša)", shortcut: model.shortcutKey(.delete)) { model.deleteSelected() },
            PaletteCommand(title: "Presunúť do priečinka…", shortcut: model.shortcutKey(.move)) { model.openFolderPicker() },
            PaletteCommand(title: "Odložiť…", shortcut: model.shortcutKey(.snooze)) { model.openSnoozePicker() },
            PaletteCommand(title: "Prejsť na Odložené", shortcut: "") { model.showingDrafts = false; model.filter = .snoozed },
            PaletteCommand(title: "Pripomenúť, ak do 3 dní neodpovie", shortcut: "") { model.setFollowUp(due: FollowUpOption.threeDays.date) },
            PaletteCommand(title: "Pripomenúť, ak do týždňa neodpovie", shortcut: "") { model.setFollowUp(due: FollowUpOption.week.date) },
            PaletteCommand(title: "Zrušiť pripomienku odpovede", shortcut: "") { model.clearFollowUp() },
            PaletteCommand(title: "Tlačiť vlákno", shortcut: "⌘P") { model.printSelectedThread() },
            PaletteCommand(title: "Exportovať vlákno ako PDF", shortcut: "") { model.exportSelectedThreadAsPDF() },
            PaletteCommand(title: "Odhlásiť z odberu (newsletter)", shortcut: "") {
                if let message = model.messages.last(where: { model.unsubscribeInfo(for: $0) != nil }) {
                    Task { await model.unsubscribe(from: message) }
                }
            },
            PaletteCommand(title: "Prejsť na Čaká na odpoveď", shortcut: "") { model.showingDrafts = false; model.filter = .followUps },
            PaletteCommand(title: "Hviezdička", shortcut: model.shortcutKey(.star)) { model.toggleStar() },
            PaletteCommand(title: "Označiť ako prečítané / neprečítané", shortcut: model.shortcutKey(.read)) { model.toggleRead() },
            PaletteCommand(title: "Štítky…", shortcut: model.shortcutKey(.tag)) { model.openTagPicker() },
            PaletteCommand(title: "Prejsť na S hviezdičkou", shortcut: "") { model.showingDrafts = false; model.filter = .starred },
            PaletteCommand(title: "Uložiť vlákno do Obsidianu", shortcut: model.shortcutKey(.obsidian)) { model.exportSelectedToObsidian() },
            PaletteCommand(title: "Otvoriť poznámku vlákna (.md)", shortcut: "") { model.openThreadNote() },
            PaletteCommand(title: "Synchronizovať", shortcut: "⌘R") { Task { await model.syncAll() } },
            PaletteCommand(title: "Prejsť na Doručenú poštu", shortcut: "⌘1") { model.showingDrafts = false; model.filter = .inbox },
            PaletteCommand(title: "Prejsť na Odoslané", shortcut: "⌘2") { model.showingDrafts = false; model.filter = .sent },
            PaletteCommand(title: "Prejsť na Koncepty", shortcut: "⌘⇧D") { model.showingDrafts = true },
            PaletteCommand(title: "Prejsť na Archív", shortcut: "⌘3") { model.showingDrafts = false; model.filter = .archive },
            PaletteCommand(title: "Prejsť na Kôš", shortcut: "⌘4") { model.showingDrafts = false; model.filter = .trash },
            PaletteCommand(title: "Prejsť na Všetku poštu", shortcut: "⌘5") { model.showingDrafts = false; model.filter = .all },
            PaletteCommand(title: "Presunúť do Doručenej pošty", shortcut: model.shortcutKey(.toInbox)) { model.moveSelectedToInbox() },
            PaletteCommand(title: "Otvoriť mail vault vo Finderi", shortcut: "") { model.revealVault() },
        ]
        // Like Pathfinder: toggle a tag on the open thread, or show threads with it.
        if let threadID = model.selectedThreadID {
            let current = model.threads.first { $0.id == threadID }?.tags ?? []
            for tag in model.menuTags {
                let on = current.contains(tag)
                list.append(PaletteCommand(title: "\(on ? "Odobrať" : "Pridať") štítok: \(tag)", shortcut: "") {
                    model.setTag(tag, !on, threadID: threadID)
                })
            }
        }
        for folder in model.foldersByAccount.values.joined() {
            list.append(PaletteCommand(title: "Prejsť na priečinok: \(folder.path.joined(separator: " / "))", shortcut: "") {
                model.showingDrafts = false
                model.filter = .folder(folder.name)
            })
        }
        for tag in model.allTags {
            list.append(PaletteCommand(title: "Zobraziť štítok: \(tag)", shortcut: "") {
                model.showingDrafts = false
                model.filter = .tag(tag)
            })
        }
        if model.settings.accounts.count > 1 {
            list.append(PaletteCommand(title: "Účet: všetky účty", shortcut: "") { model.accountScope = nil })
            for account in model.settings.accounts {
                list.append(PaletteCommand(title: "Účet: \(model.accountTitle(account))", shortcut: "") { model.accountScope = account.id })
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter { Self.fuzzyMatch(trimmed, in: $0.title) }
            list.append(PaletteCommand(title: "Hľadať „\(trimmed)“", shortcut: "↩") { model.searchText = trimmed })
        }
        return list
    }

    var body: some View {
        let commands = self.commands
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                TextField("Príkaz alebo hľadanie…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .focused($focused)
                    .onSubmit { run(commands) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, commands.count - 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { selection = 0 }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                                HStack {
                                    Text(command.title)
                                    Spacer()
                                    Text(command.shortcut)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(offset == selection ? Color.themeAccent.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = offset
                                    run(commands)
                                }
                                .id(offset)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
    }

    private func run(_ commands: [PaletteCommand]) {
        guard commands.indices.contains(selection) else { return }
        let command = commands[selection]
        close()
        command.action()
    }

    private func close() {
        model.isPaletteOpen = false
    }

    /// Letters of the query appear in order in the title, ignoring case and diacritics.
    static func fuzzyMatch(_ query: String, in title: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var remaining = Substring(fold(query))
        for ch in fold(title) where remaining.first == ch {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
