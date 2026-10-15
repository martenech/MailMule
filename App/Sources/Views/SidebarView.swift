import MailmuleKit
import SwiftUI

struct SidebarItem: Hashable {
    var account: String?
    var filter: ThreadFilter
    var drafts = false
    var scheduled = false
    var attachments = false
    var home = false
    /// A saved search's query.
    var search: String?
}

/// Which sidebar rows and sections the user hid (right-click → Skryť), like Pathfinder.
@MainActor
@Observable
final class SidebarConfig {
    private(set) var hidden: Set<String>
    /// Show hidden rows dimmed so they can be brought back.
    var revealHidden = false

    private static let key = "sidebarHidden"

    init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// Whether a row is listed: visible, or hidden while revealing.
    func lists(_ id: String) -> Bool { !hidden.contains(id) || revealHidden }

    func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.key)
        if hidden.isEmpty { revealHidden = false }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ThemeStore { .shared }
    @State private var tagToRemove: String?
    @State private var newFolderAccount: String?
    @State private var newFolderName = ""
    @State private var renaming: SavedSearch?
    @State private var renameText = ""
    @State private var renamingQuery = false
    @AppStorage("sidebarMoreExpanded") private var moreExpanded = false
    @AppStorage("sidebarAllTags") private var showAllTags = false

    private var config: SidebarConfig { model.sidebarConfig }
    private var multipleAccounts: Bool { model.settings.accounts.count > 1 }
    private static let visibleTags = 5

    var body: some View {
        VStack(spacing: 0) {
            ProfileHeader()
            ComposeButton()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            List(selection: selection) {
                Section {
                    mailboxRows(account: model.accountScope)
                }
                if config.lists("sec:more") {
                    Section(isExpanded: $moreExpanded) {
                        moreRows
                    } header: {
                        header("Ďalšie", id: "sec:more")
                    }
                }
                if config.lists("sec:accounts") {
                    Section {
                        accountRows
                    } header: {
                        header("Účty", id: "sec:accounts")
                    }
                }
                if !model.settings.savedSearches.isEmpty && config.lists("sec:searches") {
                    Section {
                        searchRows
                    } header: {
                        header("Hľadania", id: "sec:searches")
                    }
                }
                if !model.allTags.isEmpty && config.lists("sec:tags") {
                    Section {
                        tagRows
                    } header: {
                        header("Štítky", id: "sec:tags")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(theme.preset.sidebar == .system && theme.sidebarImage == nil ? .automatic : .hidden)
            footer
        }
        .background(SidebarBackdrop(style: theme.preset.sidebar, decoration: theme.sidebarDecoration).ignoresSafeArea())
        .environment(\.colorScheme, theme.sidebarImage != nil || theme.preset.sidebar != .system
                     ? (theme.sidebarIsDark ? .dark : .light) : colorScheme)
        .confirmationDialog(
            "Odstrániť štítok „\(tagToRemove ?? "")“ zo všetkých vlákien?",
            isPresented: Binding(get: { tagToRemove != nil }, set: { if !$0 { tagToRemove = nil } })
        ) {
            Button("Odstrániť", role: .destructive) {
                if let tag = tagToRemove { model.removeTagEverywhere(tag) }
                tagToRemove = nil
            }
        } message: {
            Text("Vlákna ostanú, zmizne z nich len štítok.")
        }
        .alert(renamingQuery ? "Upraviť hľadanie" : "Premenovať hľadanie", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil; renamingQuery = false } })) {
            TextField(renamingQuery ? "Hľadanie" : "Názov", text: $renameText)
            Button("Uložiť") {
                if let search = renaming, let index = model.settings.savedSearches.firstIndex(where: { $0.id == search.id }),
                   !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    let text = renameText.trimmingCharacters(in: .whitespaces)
                    if renamingQuery {
                        let wasActive = model.searchText == search.query
                        model.settings.savedSearches[index].query = text
                        if wasActive { model.searchText = text }
                    } else {
                        model.settings.savedSearches[index].name = text
                    }
                }
                renaming = nil
                renamingQuery = false
            }
            Button("Zrušiť", role: .cancel) { renaming = nil; renamingQuery = false }
        } message: {
            Text(renaming.map { renamingQuery ? $0.name : $0.query } ?? "")
        }
        .alert("Nový priečinok", isPresented: Binding(get: { newFolderAccount != nil }, set: { if !$0 { newFolderAccount = nil } })) {
            TextField("Názov", text: $newFolderName)
            Button("Vytvoriť") {
                if let account = newFolderAccount { model.createFolder(newFolderName, accountID: account) }
                newFolderName = ""
            }
            Button("Zrušiť", role: .cancel) { newFolderName = "" }
        } message: {
            Text(model.account(newFolderAccount ?? "")?.email ?? "")
        }
    }

    // MARK: - Mailboxes

    @ViewBuilder
    private func mailboxRows(account: String?) -> some View {
        let prefix = "mb:"
        row(prefix + "home") {
            Label("Prehľad", systemImage: "house")
                .tag(SidebarItem(account: account, filter: model.filter, home: true))
        }
        row(prefix + "inbox") {
            Label("Doručená pošta", systemImage: "tray")
                .badge(account.map { model.unreadByAccount[$0] ?? 0 } ?? model.inboxUnread)
                .tag(SidebarItem(account: account, filter: .inbox))
                .modifier(MoveDropTarget(target: .inbox, account: account))
        }
        row(prefix + "starred") {
            Label("S hviezdičkou", systemImage: "star")
                .tag(SidebarItem(account: account, filter: .starred))
        }
        row(prefix + "drafts") {
            Label("Koncepty", systemImage: "doc")
                .badge(model.draftCount(account: account))
                .tag(SidebarItem(account: account, filter: model.filter, drafts: true))
        }
        row(prefix + "sent") {
            Label("Odoslané", systemImage: "paperplane")
                .tag(SidebarItem(account: account, filter: .sent))
        }
        if model.outboxCount > 0 {
            Label("Odchádzajúce", systemImage: "tray.and.arrow.up")
                .badge(model.outboxCount)
                .foregroundStyle(.orange)
                .help("Správy čakajú na spojenie a odídu samy")
                .tag(SidebarItem(account: account, filter: model.filter, drafts: true, scheduled: true))
        }
        row(prefix + "scheduled") {
            Label("Naplánované", systemImage: "calendar.badge.clock")
                .badge(model.scheduledCount(account: account))
                .tag(SidebarItem(account: account, filter: model.filter, drafts: true, scheduled: true))
        }
        row(prefix + "snoozed") {
            Label("Odložené", systemImage: "clock")
                .badge(model.snoozeCount(account: account))
                .tag(SidebarItem(account: account, filter: .snoozed))
        }
        row(prefix + "attachments") {
            Label("Prílohy", systemImage: "paperclip")
                .tag(SidebarItem(account: account, filter: model.filter, attachments: true))
        }
        row(prefix + "followUps") {
            Label("Čaká na odpoveď", systemImage: "hourglass")
                .badge(model.followUpCount(account: account))
                .tag(SidebarItem(account: account, filter: .followUps))
        }
        if model.accountsInScope.contains(where: model.isGmail) {
            row(prefix + "important") {
                Label("Dôležité", systemImage: "bookmark")
                    .tag(SidebarItem(account: account, filter: .tag("\\Important")))
            }
        }
        row(prefix + "archive") {
            Label("Archív", systemImage: "archivebox")
                .tag(SidebarItem(account: account, filter: .archive))
                .modifier(MoveDropTarget(target: .archive, account: account))
        }
        row(prefix + "trash") {
            Label("Kôš", systemImage: "trash")
                .tag(SidebarItem(account: account, filter: .trash))
                .modifier(MoveDropTarget(target: .trash, account: account))
        }
        row(prefix + "junk") {
            Label("Spam", systemImage: "xmark.shield")
                .tag(SidebarItem(account: account, filter: .junk))
        }
    }

    /// "Ďalšie": all mail and the server folders of the account being viewed.
    @ViewBuilder
    private var moreRows: some View {
        row("mb:all") {
            Label("Všetka pošta", systemImage: "tray.full")
                .tag(SidebarItem(account: model.accountScope, filter: .all))
        }
        let accounts = model.focusedAccount.map { [$0] } ?? model.settings.accounts
        ForEach(accounts.filter { !(model.foldersByAccount[$0.id] ?? []).isEmpty }) { account in
            folderRows(account: account.id, scope: model.accountScope, showAccount: accounts.count > 1)
        }
        if let account = model.focusedAccount, !model.isGmail(account) {
            Button {
                newFolderAccount = account.id
            } label: {
                Label("Nový priečinok", systemImage: "plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Server folders of an account, indented by hierarchy; threads can be dropped on them.
    @ViewBuilder
    private func folderRows(account: String, scope: String?, showAccount: Bool) -> some View {
        ForEach(model.foldersByAccount[account] ?? []) { folder in
            row("folder:\(account):\(folder.name)") {
                HStack(spacing: 6) {
                    Label(folder.displayName, systemImage: "folder")
                    if showAccount {
                        Circle().fill(model.accountColor(account)).frame(width: 6, height: 6)
                    }
                }
                .padding(.leading, CGFloat(folder.depth) * 14)
                .badge(model.folderUnread[account]?[folder.name] ?? 0)
                .tag(SidebarItem(account: scope, filter: .folder(folder.name)))
                .modifier(FolderDropTarget(folder: folder, account: account))
            }
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountRows: some View {
        if multipleAccounts {
            AccountRow(account: nil)
        }
        ForEach(model.settings.accounts) { account in
            if config.lists("acct:\(account.id)") {
                AccountRow(account: account)
                    .modifier(HiddenStyle(hidden: config.isHidden("acct:\(account.id)")))
                    .contextMenu {
                        Button("Nastavenia účtu…") { openSettings() }
                        hideMenu("acct:\(account.id)", title: model.accountTitle(account))
                    }
            }
        }
        Button {
            model.addAccountRequested = true
            openSettings()
        } label: {
            Label("Pridať účet", systemImage: "plus").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tags

    /// Saved searches: selecting one runs its query.
    private var searchRows: some View {
        ForEach(model.settings.savedSearches) { search in
            Label(search.name, systemImage: "magnifyingglass")
                .help(search.query)
                .tag(SidebarItem(account: model.accountScope, filter: model.filter, search: search.query))
                .contextMenu {
                    Button("Premenovať…") { renaming = search; renameText = search.name }
                    Button("Upraviť hľadanie…") { renaming = search; renameText = search.query; renamingQuery = true }
                    Divider()
                    Button("Posunúť vyššie") { model.moveSavedSearch(search, by: -1) }
                    Button("Posunúť nižšie") { model.moveSavedSearch(search, by: 1) }
                    Divider()
                    Button("Odstrániť", role: .destructive) { model.settings.savedSearches.removeAll { $0.id == search.id } }
                }
        }
    }

    /// Tags like Pathfinder: a filled circle in the tag color (hollow without one) and a usage count.
    @ViewBuilder
    private var tagRows: some View {
        let tags = model.allTags.filter { config.lists("tag:\($0)") }
        ForEach(showAllTags ? tags : Array(tags.prefix(Self.visibleTags)), id: \.self) { tag in
            HStack {
                Label {
                    Text(tag).lineLimit(1)
                } icon: {
                    let color = model.tagColor(tag)
                    Image(systemName: color == 0 ? "circle" : "circle.fill")
                        .foregroundStyle(FinderColor.color(color) ?? .secondary)
                }
                Spacer()
                if let count = model.threadCount(forTag: tag) {
                    Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .modifier(HiddenStyle(hidden: config.isHidden("tag:\(tag)")))
            // Tags are global: their view shows threads from every account.
            .tag(SidebarItem(account: nil, filter: .tag(tag)))
            .modifier(TagDropTarget(tag: tag))
            .contextMenu {
                Menu("Farba") { TagColorChoices(tag: tag) }
                Button("Odstrániť štítok zo všetkých vlákien…", role: .destructive) { tagToRemove = tag }
                hideMenu("tag:\(tag)", title: tag)
            }
        }
        if tags.count > Self.visibleTags {
            Button {
                withAnimation { showAllTags.toggle() }
            } label: {
                Label(showAllTags ? "Menej štítkov" : "Viac štítkov…", systemImage: showAllTags ? "minus" : "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// A row that can be hidden from the sidebar (right-click), dimmed while hidden rows are revealed.
    @ViewBuilder
    private func row(_ id: String, @ViewBuilder content: () -> some View) -> some View {
        if config.lists(id) {
            content()
                .modifier(HiddenStyle(hidden: config.isHidden(id)))
                .contextMenu { hideMenu(id, title: nil) }
        }
    }

    // MARK: - Headers, hiding

    private func header(_ title: String, id: String) -> some View {
        Text(title)
            .modifier(HiddenStyle(hidden: config.isHidden(id)))
            .contextMenu { hideMenu(id, title: title) }
    }

    @ViewBuilder
    private func hideMenu(_ id: String, title: String?) -> some View {
        Divider()
        if config.isHidden(id) {
            Button(title.map { "Zobraziť „\($0)“" } ?? "Zobraziť v bočnom paneli", systemImage: "eye") {
                config.setHidden(id, false)
            }
        } else {
            Button(title.map { "Skryť „\($0)“" } ?? "Skryť z bočného panela", systemImage: "eye.slash") {
                config.setHidden(id, true)
            }
        }
        if config.revealHidden {
            Button("Znova skryť skryté položky") { config.revealHidden = false }
        } else if !config.hidden.isEmpty {
            Button("Zobraziť skryté položky (\(config.hidden.count))") { config.revealHidden = true }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if theme.sidebarDecoration && theme.sidebarIsDark {
                Text("Good ideas\nstart with a clear inbox.")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.primary.opacity(0.55))
            }
            statusLine
            HStack {
                Button { openSettings() } label: {
                    Label("Nastavenia", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Synchronizovať teraz") { Task { await model.syncAll() } }
                    Button("Otvoriť mail vault vo Finderi") { model.revealVault() }
                    if !config.hidden.isEmpty || config.revealHidden {
                        Divider()
                        Button(config.revealHidden ? "Znova skryť skryté položky" : "Zobraziť skryté položky (\(config.hidden.count))") {
                            withAnimation { config.revealHidden.toggle() }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        let history = model.historyRemaining.values.reduce(0, +)
        if !model.isOnline {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                Text(model.outboxCount > 0 ? "Bez pripojenia · \(model.outboxCount) čaká na odoslanie" : "Bez pripojenia").lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.orange)
        } else if let maintenance = model.maintenance {
            status(maintenance)
        } else if history > 0 {
            status("Sťahujem staršiu poštu · \(history)")
        } else if model.isSyncing {
            status("Synchronizujem…")
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.primary.opacity(0.5))
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(account: model.accountScope, filter: model.filter, drafts: model.showingDrafts,
                               scheduled: model.showingDrafts && model.showingScheduled,
                               attachments: model.showingAttachments, home: model.showingHome,
                               search: model.activeSavedSearch?.query) },
            set: { item in
                guard let item else { return }
                model.showingDrafts = item.drafts
                model.showingScheduled = item.scheduled
                model.accountScope = item.account
                model.filter = item.filter
                model.showingAttachments = item.attachments
                model.showingHome = item.home
                if let query = item.search {
                    model.searchText = query
                } else if model.activeSavedSearch != nil {
                    model.searchText = ""
                }
            }
        )
    }
}

/// Sidebar background for the theme: Mailmule's dark gradient, a palette color, or nothing (system sidebar).
/// Mountains are drawn at the bottom of dark sidebars when the decoration is on.
private struct SidebarBackdrop: View {
    let style: ThemePreset.SidebarStyle
    let decoration: Bool

    private var theme: ThemeStore { .shared }

    var body: some View {
        if let image = theme.sidebarImage {
            // A picture: fill the sidebar (anchored at the bottom, where the scenery usually is)
            // and veil it so the text on top stays readable.
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    .clipped()
                    .overlay((theme.sidebarIsDark ? Color.black : Color.white).opacity(theme.sidebarScrim))
            }
        } else {
            themeBackground
        }
    }

    private var themeBackground: some View {
        ZStack(alignment: .bottom) {
            switch style {
            case .system:
                Color.clear
            case .mailmule:
                LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.09, green: 0.10, blue: 0.13)],
                               startPoint: .top, endPoint: .bottom)
            case .color(let color):
                color
            }
            if decoration && theme.preset.hasDarkSidebar {
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height
                    ZStack {
                        Mountains(peaks: [0.0: 0.62, 0.22: 0.78, 0.45: 0.58, 0.7: 0.83, 1.0: 0.66])
                            .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        Mountains(peaks: [0.0: 0.78, 0.3: 0.68, 0.55: 0.86, 0.8: 0.72, 1.0: 0.8])
                            .fill(LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    }
                    .frame(width: w, height: min(220, h * 0.3))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

/// A ridge line through the given (x, height) points, both as fractions of the frame.
private struct Mountains: Shape {
    let peaks: [Double: Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = peaks.sorted { $0.key < $1.key }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (x, height) in points {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * x, y: rect.maxY - rect.height * height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The big "Nová správa" button with its shortcut.
private struct ComposeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.composeNew() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                Text("Nová správa").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("⌘ N")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.themeAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nová správa (c, ⌘N)")
    }
}

/// The account being viewed, with a menu to switch accounts.
private struct ProfileHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let account = model.focusedAccount
        Menu {
            if model.settings.accounts.count > 1 {
                Button("Všetky účty") { switchTo(nil) }
            }
            ForEach(model.settings.accounts) { item in
                Button(model.hasAccountLabel(item) ? "\(model.accountTitle(item)) – \(item.email)" : item.email) { switchTo(item.id) }
            }
            Divider()
            Button("Pridať účet…") {
                model.addAccountRequested = true
                openSettings()
            }
        } label: {
            HStack(spacing: 10) {
                Text(initials(account?.name ?? "Všetky"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background((account.map { model.accountColor($0.id) } ?? .accentColor).gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.map { model.hasAccountLabel($0) ? model.accountTitle($0) : $0.name } ?? "Všetky účty")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(account?.email ?? "\(model.settings.accounts.count) účty")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func switchTo(_ id: String?) {
        model.showingDrafts = false
        model.accountScope = id
        model.filter = .inbox
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// An account in the "Účty" section; nil is the unified "Všetky účty". Clicking shows that account.
private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account?

    private var isActive: Bool { model.accountScope == account?.id }

    var body: some View {
        let color = account.map { model.accountColor($0.id) } ?? .accentColor
        Button {
            model.showingDrafts = false
            model.accountScope = account?.id
            model.filter = .inbox
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient)
                    if let account, model.isGmail(account) {
                        Text("G").font(.system(size: 11, weight: .bold, design: .rounded))
                    } else if account == nil {
                        Image(systemName: "tray.2.fill").font(.system(size: 9, weight: .semibold))
                    } else {
                        Image(systemName: "envelope.fill").font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                Text(account.map(model.accountTitle) ?? "Všetky účty")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account?.email ?? "")
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer(minLength: 4)
                if let id = account?.id, let error = model.syncErrors[id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Synchronizácia zlyhala: \(error)")
                } else {
                    let unread = account.map { model.unreadByAccount[$0.id] ?? 0 } ?? model.inboxUnread
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(isActive ? Color.themeAccent : .secondary.opacity(0.35), in: Capsule())
                    }
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(isActive ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(account.map { "\(model.accountTitle($0)) · \($0.name) · \($0.email)" } ?? "Spoločná pošta všetkých účtov")
    }
}

/// Hidden rows (shown only while revealing) are dimmed with an eye-slash, like in Pathfinder.
private struct HiddenStyle: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            HStack(spacing: 4) {
                content
                    .lineLimit(1)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Skryté")
            }
        } else {
            content
        }
    }
}

/// Accepts threads dragged from the list and moves them to this folder.
/// A folder of a specific account only accepts that account's threads.
private struct MoveDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: ThreadFilter
    let account: String?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 1)
            .background(isTargeted ? Color.themeAccent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .dropDestination(for: String.self) { payloads, _ in
                // A drag carries one or more thread IDs separated by newlines.
                let ids = payloads.flatMap { $0.split(separator: "\n").map(String.init) }
                let movable = ids.filter { id in
                    guard let thread = model.threads.first(where: { $0.id == id }) else { return false }
                    return account == nil || thread.accountID == account
                }
                model.move(movable, to: target)
                return !movable.isEmpty
            } isTargeted: { isTargeted = $0 }
    }
}

/// Dropping a thread on a tag in the sidebar adds the tag.
private struct TagDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tag: String
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 1)
            .background(isTargeted ? Color.themeAccent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .dropDestination(for: String.self) { payloads, _ in
                // A drag carries one or more thread IDs separated by newlines.
                let ids = payloads.flatMap { $0.split(separator: "\n").map(String.init) }
                model.setTag(tag, true, threadIDs: ids)
                return !ids.isEmpty
            } isTargeted: { isTargeted = $0 }
    }
}

/// Dropping threads on a folder moves them there (only threads of that folder's account).
private struct FolderDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo
    let account: String
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 1)
            .background(isTargeted ? Color.themeAccent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .dropDestination(for: String.self) { payloads, _ in
                // A drag carries one or more thread IDs separated by newlines.
                let ids = payloads.flatMap { $0.split(separator: "\n").map(String.init) }
                let movable = ids.filter { id in model.threads.first { $0.id == id }?.accountID == account }
                model.move(movable, toFolder: folder)
                return !movable.isEmpty
            } isTargeted: { isTargeted = $0 }
    }
}
