import MailmuleKit
import SwiftUI

struct ThreadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if model.listView.grouping == .none {
                rows(model.threads)
            } else {
                ForEach(groups, id: \.title) { group in
                    Section {
                        rows(group.threads)
                    } header: {
                        HStack {
                            Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                            Spacer()
                            Text(Self.messagesLabel(group.threads.count))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Double-click opens the thread in its own window; this keeps single clicks for selecting
        // (a tap gesture on the rows would swallow them). Row menus stay on the rows.
        .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
            if let id = ids.first { model.openThreadWindow(id) }
        })
        .listStyle(.inset)
        .scrollContentBackground(ThemeStore.shared.customizesContent ? .hidden : .automatic)
        .background { if ThemeStore.shared.customizesContent { ThemedBackground() } }
        .safeAreaInset(edge: .top, spacing: 0) { ListHeader() }
        .overlay {
            if model.threads.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.isSyncing {
                    ProgressView("Sťahujem poštu…")
                } else if model.listView.options.unreadOnly || model.listView.options.attachmentsOnly
                            || model.listView.options.starredOnly {
                    ContentUnavailableView("Nič nezodpovedá filtru", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Prepni na „Všetky“."))
                } else if model.filter == .inbox {
                    ContentUnavailableView("Inbox zero", systemImage: "checkmark.circle", description: Text("Žiadne vlákna v doručenej pošte."))
                } else if model.filter == .trash {
                    ContentUnavailableView("Kôš je prázdny", systemImage: "trash")
                } else if model.filter == .snoozed {
                    ContentUnavailableView("Nič nie je odložené", systemImage: "clock",
                                           description: Text("Klávesom h odložíš vlákno na neskôr."))
                } else if model.filter == .starred {
                    ContentUnavailableView("Žiadne vlákna s hviezdičkou", systemImage: "star", description: Text("Hviezdičku pridáš klávesom s."))
                } else if model.filter == .archive {
                    ContentUnavailableView("Archív je prázdny", systemImage: "archivebox", description: Text("Archivované vlákna (e) sa zobrazia tu."))
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(model.accountScope.flatMap { model.account($0)?.email } ?? "")
    }

    @ViewBuilder
    private func rows(_ threads: [ThreadSummary]) -> some View {
        ForEach(threads) { thread in
            Group {
                if model.listView.density == .compact {
                    CompactThreadRow(thread: thread)
                } else {
                    ThreadRow(thread: thread)
                }
            }
            .tag(thread.id)
            .draggable(model.targets(including: thread.id).joined(separator: "\n")) {
                let count = model.targets(including: thread.id).count
                Label(count > 1 ? "\(count) vlákien" : (thread.subject.isEmpty ? "(bez predmetu)" : thread.subject),
                      systemImage: count > 1 ? "envelope.stack" : "envelope")
                    .padding(6)
            }
            .contextMenu { ThreadContextMenu(threadID: thread.id) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { swipeButton(model.settings.swipeLeading, thread) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButton(model.settings.swipeTrailing, thread) }
        }
    }

    /// Swipe actions from Nastavenia → Pravidlá a automatizácie.
    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, _ thread: ThreadSummary) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .archive:
            Button { model.move([thread.id], to: .archive) } label: { Label(action.title, systemImage: action.symbol) }
                .tint(.blue)
        case .delete:
            Button(role: .destructive) { model.move([thread.id], to: .trash) } label: { Label(action.title, systemImage: action.symbol) }
        case .star:
            Button { model.toggleStar([thread.id]) } label: {
                Label(thread.flagged ? "Zrušiť hviezdičku" : action.title, systemImage: thread.flagged ? "star.slash" : "star")
            }
            .tint(.yellow)
        case .read:
            Button { model.toggleRead([thread.id]) } label: {
                Label(thread.isUnread ? "Prečítané" : "Neprečítané", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
            }
            .tint(.indigo)
        case .snooze:
            Button { model.openSnoozePicker([thread.id]) } label: { Label(action.title, systemImage: action.symbol) }
                .tint(.orange)
        }
    }

    private struct ThreadGroup {
        let title: String
        var threads: [ThreadSummary]
    }

    /// Groups in the order they first appear in the (already sorted) list.
    private var groups: [ThreadGroup] {
        var result: [ThreadGroup] = []
        var positions: [String: Int] = [:]
        for thread in model.threads {
            let title = model.listView.grouping == .sender
                ? (thread.latestSender.isEmpty ? "Neznámy odosielateľ" : thread.latestSender)
                : Self.dateGroup(thread.date)
            if let position = positions[title] {
                result[position].threads.append(thread)
            } else {
                positions[title] = result.count
                result.append(ThreadGroup(title: title, threads: [thread]))
            }
        }
        return result
    }

    /// "1 správa", "3 správy", "5 správ".
    static func messagesLabel(_ count: Int) -> String {
        switch count {
        case 1: "1 správa"
        case 2...4: "\(count) správy"
        default: "\(count) správ"
        }
    }

    static func dateGroup(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Dnes" }
        if calendar.isDateInYesterday(date) { return "Včera" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) { return "Tento týždeň" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: Date()),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return "Minulý týždeň" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return "Tento mesiac" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date).capitalized
    }

    private var title: String {
        if let saved = model.activeSavedSearch { return saved.name }
        if !model.searchText.isEmpty { return "Výsledky hľadania" }
        switch model.filter {
        case .inbox: return "Doručená pošta"
        case .sent: return "Odoslané"
        case .archive: return "Archív"
        case .trash: return "Kôš"
        case .all: return "Všetka pošta"
        case .starred: return "S hviezdičkou"
        case .tag("\\Important"): return "Dôležité"
        case .tag(let tag): return tag
        case .folder(let mailbox): return model.folderName(mailbox)
        case .junk: return "Spam"
        case .snoozed: return "Odložené"
        case .followUps: return "Čaká na odpoveď"
        }
    }
}

struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary

    /// In the unified view with several accounts, a colored bar shows which account the thread belongs to.
    private var showsAccount: Bool {
        model.settings.accounts.count > 1 && model.accountScope == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAccount {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(model.accountColor(thread.accountID))
                    .frame(width: 3)
                    .help(model.account(thread.accountID)?.email ?? "")
            }
            Circle()
                .fill(thread.isUnread ? Color.themeAccent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 15)
            SenderAvatar(name: thread.latestSender.isEmpty ? thread.participants.first ?? "?" : thread.latestSender,
                         address: thread.latestSenderAddress,
                           emphasized: thread.isUnread, size: model.settings.largeAvatars ? 44 : 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(senders)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .medium))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if let wake = model.snoozes[thread.id] {
                        Label(SnoozeOption.describe(wake), systemImage: "clock")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.themeAccent)
                            .help("Vráti sa do Doručenej pošty")
                    } else {
                        if let action = thread.lastAction { ThreadActionIcon(action: action) }
                        Text(Self.shortDate(thread.date))
                            .font(.system(size: 11, weight: thread.isUnread ? .semibold : .regular))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    Text(thread.subject.isEmpty ? "(bez predmetu)" : thread.subject)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if let followUp = model.followUps[thread.id] { FollowUpBadge(followUp: followUp) }
                    if !thread.tags.isEmpty { TagDots(tags: thread.tags) }
                }
                HStack(alignment: .top, spacing: 6) {
                    if model.settings.showPreview {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(model.settings.previewLines, reservesSpace: true)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if thread.flagged {
                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow)
                    }
                }
            }
        }
        .padding(.vertical, model.settings.rowSpacing.padding)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    private var senders: String {
        let people = model.otherParticipants(thread)
        let names = people.prefix(3).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        // A single sender keeps the full name; several are shortened to first names, like Mail.
        return people.count == 1 ? people[0] : names.joined(separator: ", ")
    }

    private var preview: String { thread.preview }

    static func shortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Včera"
        }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// "Čakám do 17. 10." while waiting for an answer, orange "Bez odpovede" once the time passed.
struct FollowUpBadge: View {
    let followUp: FollowUp

    var body: some View {
        let color: Color = followUp.fired ? .orange : .secondary
        Label(followUp.fired ? "Bez odpovede" : "Čakám do \(followUp.due.formatted(.dateTime.day().month(.defaultDigits)))",
              systemImage: "hourglass")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
            .help(followUp.fired ? "Neodpovedal do \(SnoozeOption.describe(followUp.due))" : "Ak neodpovie, vlákno sa \(SnoozeOption.describe(followUp.due)) vráti do Doručenej")
    }
}

/// ↩ answered or ↪ forwarded, like Mail.app.
struct ThreadActionIcon: View {
    let action: ThreadAction

    var body: some View {
        Image(systemName: action == .replied ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.right.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(action == .replied ? Color.themeAccent : Color.purple)
            .frame(width: 20, height: 18)
            .background((action == .replied ? Color.themeAccent : Color.purple).opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .help(action == .replied ? "Odpovedal si" : "Preposlal si")
    }
}

/// Right-click actions for a thread in the list; they apply to the whole selection when the row is in it.
struct ThreadContextMenu: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        Button("Otvoriť v novom okne") { model.openThreadWindow(threadID) }
        Divider()
        let ids = model.targets(including: threadID)
        let selected = model.threads.filter { ids.contains($0.id) }
        if ids.count > 1 {
            Text("\(ids.count) vybraných vlákien")
        }
        if model.filter != .inbox || !model.searchText.isEmpty {
            Button("Presunúť do Doručenej pošty") { model.move(ids, to: .inbox) }
        }
        if model.filter != .archive || !model.searchText.isEmpty {
            Button("Archivovať") { model.move(ids, to: .archive) }
        }
        Button(model.filter == .trash ? "Zmazať natrvalo" : "Presunúť do koša", role: .destructive) {
            model.move(ids, to: .trash)
        }
        let folders = model.folders(forThreads: ids)
        if !folders.isEmpty {
            Menu("Presunúť do") {
                ForEach(folders) { folder in
                    Button(String(repeating: "   ", count: folder.depth) + folder.displayName) {
                        model.move(ids, toFolder: folder)
                    }
                }
            }
        }
        Button("Presunúť do…") { model.openFolderPicker(ids) }
        Menu("Odložiť") {
            ForEach(SnoozeOption.presets()) { option in
                Button("\(option.title) – \(SnoozeOption.describe(option.date))") { model.snooze(ids, until: option.date) }
            }
            Divider()
            Button("Vlastný čas…") { model.openSnoozePicker(ids) }
        }
        if ids.contains(where: { model.followUps[$0] != nil }) {
            Button("Zrušiť pripomienku odpovede") { model.clearFollowUp(ids) }
        } else {
            Menu("Pripomenúť, ak neodpovie") {
                ForEach(FollowUpOption.allCases, id: \.self) { option in
                    Button("\(option.title) – \(SnoozeOption.describe(option.date))") { model.setFollowUp(ids, due: option.date) }
                }
            }
        }
        Divider()
        Button(selected.allSatisfy(\.flagged) ? "Odstrániť hviezdičku" : "Označiť hviezdičkou") { model.toggleStar(ids) }
        Button(selected.contains(where: \.isUnread) ? "Označiť ako prečítané" : "Označiť ako neprečítané") { model.toggleRead(ids) }
        Menu("Štítky") {
            let current = model.commonTags(ids)
            ForEach(model.menuTags, id: \.self) { tag in
                Toggle(isOn: Binding(get: { current.contains { Tags.fold($0) == Tags.fold(tag) } },
                                     set: { model.setTag(tag, $0, threadIDs: ids) })) {
                    Label {
                        Text(tag)
                    } icon: {
                        Image(systemName: model.tagColor(tag) == 0 ? "circle" : "circle.fill")
                            .foregroundStyle(FinderColor.color(model.tagColor(tag)) ?? .secondary)
                    }
                }
            }
            Divider()
            Button("Iný štítok…") { model.openTagPicker(ids) }
        }
        if ids.count == 1 {
            Divider()
            Button("Uložiť do Obsidianu") {
                model.selectedThreadID = threadID
                model.exportSelectedToObsidian()
            }
        }
    }
}

/// Single-line row for the compact density: sender, subject and preview on one line.
struct CompactThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: 8) {
            if model.settings.accounts.count > 1 && model.accountScope == nil {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(model.accountColor(thread.accountID))
                    .frame(width: 3, height: 14)
            }
            Circle()
                .fill(thread.isUnread ? Color.themeAccent : .clear)
                .frame(width: 7, height: 7)
            Text(thread.latestSender.isEmpty ? thread.participants.first ?? "" : thread.latestSender)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .foregroundStyle(thread.isUnread ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            (Text(thread.subject.isEmpty ? "(bez predmetu)" : thread.subject)
                .fontWeight(thread.isUnread ? .semibold : .regular)
             + Text("  ") + Text(thread.preview).foregroundStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !thread.tags.isEmpty { TagDots(tags: thread.tags) }
            if thread.hasAttachments {
                Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
            }
            if thread.flagged {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            if let action = thread.lastAction { ThreadActionIcon(action: action) }
            Text(ThreadRow.shortDate(thread.date))
                .font(.caption.weight(thread.isUnread ? .semibold : .regular))
                .foregroundStyle(thread.isUnread ? Color.themeAccent : .secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }
}

/// The "Zobrazenie" menu: sorting, grouping, quick filters and row density.
struct ListViewMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            ListViewMenuItems()
        } label: {
            Label("Zobrazenie", systemImage: "slider.horizontal.3")
                .foregroundStyle(isFiltered ? Color.themeAccent : .secondary)
        }
        .help("Radenie, zoskupenie, filtre a hustota zoznamu")
    }

    private var isFiltered: Bool {
        model.listView.options.sort != .newest || model.listView.grouping != .none
    }
}

/// Menu contents shared by the toolbar menu and the app's View menu.
struct ListViewMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Radiť", selection: $model.listView.options.sort) {
            Text("Najnovšie navrchu").tag(ThreadSort.newest)
            Text("Najstaršie navrchu").tag(ThreadSort.oldest)
            Text("Podľa odosielateľa").tag(ThreadSort.sender)
            Text("Podľa predmetu").tag(ThreadSort.subject)
            Text("Neprečítané navrchu").tag(ThreadSort.unreadFirst)
        }
        Picker("Zoskupiť", selection: $model.listView.grouping) {
            Text("Nezoskupovať").tag(ListGrouping.none)
            Text("Podľa dátumu").tag(ListGrouping.date)
            Text("Podľa odosielateľa").tag(ListGrouping.sender)
        }
        Divider()
        Picker("Hustota", selection: $model.listView.density) {
            Text("Štandardná").tag(ListDensity.comfortable)
            Text("Kompaktná").tag(ListDensity.compact)
        }
    }
}

extension ThreadSummary {
    /// Snippet without leftover Markdown markers.
    var preview: String {
        snippet
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
}

/// Search field and quick filter tabs above the thread list.
struct ListHeader: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var savingSearch = false
    @State private var searchName = ""

    private enum QuickFilter: String, CaseIterable {
        case all = "Všetky", unread = "Neprečítané", attachments = "S prílohami", starred = "Označené"
    }

    private var current: QuickFilter {
        let options = model.listView.options
        if options.unreadOnly { return .unread }
        if options.attachmentsOnly { return .attachments }
        if options.starredOnly { return .starred }
        return .all
    }

    private func select(_ filter: QuickFilter) {
        var options = model.listView.options
        options.unreadOnly = filter == .unread
        options.attachmentsOnly = filter == .attachments
        options.starredOnly = filter == .starred
        model.listView.options = options
    }

    /// Examples inserted by the filter menu next to the search field.
    private static let operators: [(String, String)] = [
        ("od:", "Od odosielateľa"),
        ("komu:", "Pre príjemcu"),
        ("predmet:", "V predmete"),
        ("má:prílohu", "S prílohou"),
        ("je:neprečítané", "Neprečítané"),
        ("je:hviezdička", "S hviezdičkou"),
        ("po:\(Date().formatted(.iso8601.year().month()))", "Od dátumu"),
        ("pred:\(Date().formatted(.iso8601.year().month()))", "Pred dátumom"),
    ]

    private func insertOperator(_ example: String) {
        let current = model.searchText.trimmingCharacters(in: .whitespaces)
        model.searchText = current.isEmpty ? example : current + " " + example
        searchFocused = true
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Hľadať v pošte… (od:, má:prílohu, po:)", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.escape) {
                        model.searchText = ""
                        searchFocused = false
                        return .handled
                    }
                Menu {
                    Section("Pridať do hľadania") {
                        ForEach(Self.operators, id: \.0) { example, title in
                            Button("\(title)  –  \(example)") { insertOperator(example) }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Operátory: od:, komu:, predmet:, má:prílohu, je:neprečítané, je:hviezdička, po:2026-09, pred:2026-10. Fráza v úvodzovkách.")
                if model.searchText.isEmpty {
                    Text("/")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    if model.activeSavedSearch == nil {
                        Button { searchName = ""; savingSearch = true } label: {
                            Image(systemName: "bookmark").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Uložiť hľadanie do bočného panela")
                    }
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        Button {
                            select(filter)
                        } label: {
                            Text(filter.rawValue)
                                .font(.callout.weight(current == filter ? .semibold : .regular))
                                .foregroundStyle(current == filter ? Color.white : .secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                                .background(current == filter ? Color.themeAccent : .clear, in: Capsule())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(.quaternary.opacity(0.6), in: Capsule())
                ListViewMenu()
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background { ThemedBackground(fallback: Color(nsColor: .textBackgroundColor)) }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .alert("Uložiť hľadanie", isPresented: $savingSearch) {
            TextField("Názov", text: $searchName, prompt: Text(model.searchText))
            Button("Uložiť") { model.saveSearch(name: searchName) }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("„\(model.searchText.trimmingCharacters(in: .whitespaces))“ sa zobrazí v bočnom paneli v sekcii Hľadania.")
        }
    }
}

/// Initials in a circle: dark for unread threads, light gray once read (as in the design).
struct InitialsAvatar: View {
    let name: String
    var emphasized = false
    var size: CGFloat = 34

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.93), Color(red: 0.55, green: 0.42, blue: 0.86), Color(red: 0.89, green: 0.45, blue: 0.62),
        Color(red: 0.93, green: 0.55, blue: 0.30), Color(red: 0.30, green: 0.68, blue: 0.55), Color(red: 0.24, green: 0.66, blue: 0.78),
        Color(red: 0.75, green: 0.58, blue: 0.30), Color(red: 0.50, green: 0.58, blue: 0.66),
    ]

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        // The same name always gets the same color (stable across launches, unlike hashValue).
        let seed = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let color = Self.palette[seed % Self.palette.count]
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.36, weight: emphasized ? .bold : .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.opacity(emphasized ? 1 : 0.75).gradient, in: Circle())
    }
}
