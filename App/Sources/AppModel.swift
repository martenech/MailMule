import AppKit
import EventKit
import MailmuleKit
import Network
import Observation
import OSLog
import SwiftUI

/// The message being written; the same type is stored as a draft in the vault.
typealias ComposeDraft = SavedDraft

enum ComposeKind {
    case new, reply, forward

    init(_ draft: ComposeDraft) {
        if draft.inReplyTo != nil { self = .reply }
        else if draft.subject.lowercased().hasPrefix("fwd:") { self = .forward }
        else { self = .new }
    }
}

enum ListGrouping: String, Codable, CaseIterable {
    case none, date, sender
}

enum ListDensity: String, Codable, CaseIterable {
    case comfortable, compact
}

/// Thread list view settings, remembered between launches.
struct ListViewSettings: Codable, Equatable {
    var options = ThreadListOptions()
    var grouping: ListGrouping = .date
    var density: ListDensity = .comfortable

    private static let key = "listView"

    static func load() -> ListViewSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(ListViewSettings.self, from: data) else { return ListViewSettings() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// A sent message waiting out its "zrušiť odoslanie" window.
struct PendingSend {
    let id: UUID
    let draft: ComposeDraft
    let archive: Bool?
    let followUp: Date?
    let deadline: Date
    let task: Task<Void, Never>
}

/// An archive or delete waiting out its undo window.
struct PendingAction: Identifiable {
    enum Kind {
        case archive, delete, deleteForever, moveToInbox
        /// Move to a server folder: mailbox name and display name.
        case moveToFolder(String, String)
        /// Snooze until the date.
        case snooze(Date)

        var title: String {
            switch self {
            case .snooze(let date): "Odložené do \(SnoozeOption.describe(date))"
            case .archive: "Presunuté do archívu"
            case .delete: "Presunuté do koša"
            case .deleteForever: "Zmazané natrvalo"
            case .moveToInbox: "Presunuté do Doručenej pošty"
            case .moveToFolder(_, let display): "Presunuté do „\(display)“"
            }
        }
    }

    static let undoWindow = Duration.seconds(5)

    let id: UUID
    let kind: Kind
    /// Affected threads with their positions in the list (for undo).
    let threads: [(thread: ThreadSummary, position: Int)]
    let hidden: Bool
    let task: Task<Void, Never>

    var title: String {
        threads.count > 1 ? "\(kind.title) (\(threads.count))" : kind.title
    }
}

@MainActor @Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            settings.save()
            applyEditorSettings()
        }
    }

    /// Editor font size and spell checking language.
    func applyEditorSettings() {
        AvatarStore.shared.loadsLogos = settings.senderLogos
        MarkdownStyler.baseFontSize = settings.editorFontSize
        let checker = NSSpellChecker.shared
        if settings.spellingLanguage == "auto" {
            // Detect Slovak, Czech, English… per paragraph instead of checking everything as English.
            checker.automaticallyIdentifiesLanguages = true
        } else {
            checker.automaticallyIdentifiesLanguages = false
            checker.setLanguage(settings.spellingLanguage)
        }
    }

    var filter: ThreadFilter = .inbox {
        didSet {
            if filter != oldValue { reload() }
            // Going to a mailbox (⌘1, menus, palette) leaves the Prílohy view and Prehľad.
            showingAttachments = false
            showingHome = false
        }
    }

    /// nil = all accounts (unified view).
    var accountScope: String? {
        didSet { if accountScope != oldValue { reload() } }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            // Search results are threads, so leave the Drafts folder.
            if !searchText.isEmpty { showingDrafts = false }
            reload()
        }
    }

    private(set) var threads: [ThreadSummary] = []

    var listView = ListViewSettings.load() {
        didSet {
            guard listView != oldValue else { return }
            listView.save()
            if listView.options != oldValue.options { reload() }
        }
    }
    private(set) var messages: [StoredMessage] = []
    private(set) var inboxUnread = 0
    private(set) var unreadByAccount: [String: Int] = [:]
    /// Last sync error per account, shown next to the account in the sidebar.
    private(set) var syncErrors: [String: String] = [:]
    private(set) var isSyncing = false
    /// Long-running local work shown in the sidebar footer (e.g. freeing space).
    private(set) var maintenance: String?
    private(set) var lastSync: Date?

    /// The thread shown in the detail pane; nil when nothing or several threads are selected.
    var selectedThreadID: String? {
        didSet {
            guard selectedThreadID != oldValue else { return }
            if let id = selectedThreadID {
                if selection != [id] { selection = [id] }
            } else if selection.count == 1 {
                selection = []
            }
            loadSelectedThread()
        }
    }

    /// Threads selected in the list (⇧ / ⌘ click, ⌘A); actions apply to all of them.
    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            let single = selection.count == 1 ? selection.first : nil
            if selectedThreadID != single { selectedThreadID = single }
        }
    }

    /// Threads an action applies to: the selection in list order, or the open thread.
    var targetThreadIDs: [String] {
        if selection.count > 1 { return threads.map(\.id).filter(selection.contains) }
        return selectedThreadID.map { [$0] } ?? []
    }

    /// For context menus and drags: the whole selection when the row is part of it, else just the row.
    func targets(including rowID: String) -> [String] {
        selection.contains(rowID) && selection.count > 1 ? targetThreadIDs : [rowID]
    }

    var errorMessage: String? {
        didSet {
            // Demo mode has no servers; their errors would only cover the screenshots.
            if Demo.isActive, errorMessage != nil { errorMessage = nil }
        }
    }
    var toast: String?
    var compose: ComposeDraft?
    private(set) var pendingActions: [PendingAction] = []
    private(set) var drafts: [SavedDraft] = []
    private(set) var allTags: [String] = []
    /// Custom server folders per account (empty for Gmail).
    private(set) var foldersByAccount: [String: [FolderInfo]] = [:]
    /// Unread threads per server folder, per account.
    private(set) var folderUnread: [String: [String: Int]] = [:]
    /// Older messages still to download, per account.
    private(set) var historyRemaining: [String: Int] = [:]
    /// Threads being snoozed with the snooze picker (`h`); nil when the picker is closed.
    var snoozePickerThreadIDs: [String]?
    /// When each snoozed thread comes back.
    private(set) var snoozes: [String: Date] = [:]
    /// "Pripomenúť, ak neodpovie" reminders by thread.
    private(set) var followUps: [String: FollowUp] = [:]
    private var snoozeTimer: Task<Void, Never>?
    /// Threads being moved with the folder picker (`v`); nil when the picker is closed.
    var folderPickerThreadIDs: [String]?
    let tagCatalog = TagCatalog()
    let sidebarConfig = SidebarConfig()
    /// Threads per tag, shown in the sidebar.
    private(set) var tagCounts: [String: Int] = [:]
    /// Threads whose tags are being edited in the tag picker (`l`); nil when the picker is closed.
    var tagPickerThreadIDs: [String]?
    /// The Drafts folder is shown instead of a thread list.
    var showingDrafts = false {
        didSet { if showingDrafts { showingAttachments = false; showingHome = false } }
    }
    /// The Prílohy view (all attachments) instead of the thread list.
    var showingAttachments = false {
        didSet { if showingAttachments { showingHome = false } }
    }
    /// The Prehľad page (home) instead of the mail columns.
    var showingHome = false
    /// Bumped when the Mac's calendar changes, so Prehľad reloads.
    var calendarRevision = 0
    private var calendarObserver: NSObjectProtocol?
    private var sendingDue = false
    private var pathMonitor: NWPathMonitor?
    /// False while macOS reports no network.
    private(set) var isOnline = true
    /// With `showingDrafts`: the scheduled messages instead of plain drafts.
    var showingScheduled = false
    var isPaletteOpen = false
    /// Set by "Pridať účet" so the settings window opens on an empty account form.
    var addAccountRequested = false
    /// Incremented to ask the window to focus the search field.
    var searchFocusRequest = 0

    /// Autocomplete for To/Cc: people from the mail history plus macOS Contacts.
    let addressBook = AddressBook()
    /// On-device language model for summaries and reply suggestions.
    let localModel = LocalModel()
    /// Thread summaries (streamed while they are written, kept in the index afterwards).
    var summaries: [String: String] = [:]
    /// The stored summary predates the thread's newest message.
    var summaryOutdated: [String: Bool] = [:]
    /// The thread whose summary is being written.
    var summarizing: String?
    /// Asked before the first, multi-gigabyte model download.
    var assistantDownloadRequest: AssistantRequest?
    /// Incremented after the download was confirmed for a reply suggestion; the reply bar then starts it.
    var replySuggestionRequest = 0

    /// The message in its undo-send window.
    var pendingSend: PendingSend?
    /// Asks the main window to open another window (it holds the openWindow action).
    var windowRequest: WindowRequest?
    /// Drafts handed to compose windows by ID.
    var windowDrafts: [UUID: ComposeDraft] = [:]
    /// Accounts of threads open in their own windows (they may not be in the current list).
    var windowThreadAccounts: [String: String] = [:]

    /// The person card opened by a mailmule://person link.
    var personSheet: PersonSheet?

    /// Attachment viewer windows: their files and the one shown.
    var viewerSessions: [String: ViewerSession] = [:]

    /// The page shown in the Settings window.
    var settingsCategory: SettingsCategory = .accounts
    /// Incremented to ask the main window to open Settings (it owns the openSettings action).
    var settingsOpenRequest = 0

    /// When each account last finished a sync (shown in Settings).
    var accountLastSync: [String: Date] = [:]

    private(set) var index: MailIndex?
    private var vault: MailVault?
    private var draftStore: DraftStore?
    private var draftUploads: [UUID: Task<Void, Never>] = [:]
    private var services: [String: AccountService] = [:]
    private var watchers: [String: IdleWatcher] = [:]
    /// Accounts whose first sync in this session finished; only later syncs notify about new mail.
    private var initialSyncDone: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var backfillTasks: [String: Task<Void, Never>] = [:]
    private var syncLoop: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var mimeCache: [String: MIMEMessage] = [:]
    private var started = false

    static let logger = Logger(subsystem: "app.mailmule.Mailmule", category: "app")

    init() {
        settings = AppSettings.load()
        if Demo.isActive && settings.accounts.isEmpty { settings = Demo.settings }
        showingHome = settings.openHomeOnLaunch
        calendarObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarRevision += 1 }
        }
        applyEditorSettings()
        Self.clearAttachmentCache()
        tagCatalog.setOverrides(settings.tagColors)
    }

    var needsSetup: Bool { settings.accounts.isEmpty }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadID } }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await configure()
    }

    /// (Re)creates the vault, index and account services from settings and starts periodic sync.
    func configure() async {
        syncLoop?.cancel()
        for watcher in watchers.values { await watcher.stop() }
        watchers = [:]
        for task in backfillTasks.values { task.cancel() }
        backfillTasks = [:]
        for service in services.values { await service.disconnect() }
        services = [:]
        initialSyncDone = []
        mimeCache = [:]
        guard !settings.accounts.isEmpty else { return }
        if let scope = accountScope, account(scope) == nil { accountScope = nil }

        let vault = MailVault(root: settings.mailVaultURL)
        do {
            try vault.prepare()
            // Keep the open index when the vault did not move: opening a second connection while
            // background work still writes to the first one ends in "database is locked".
            if let existing = index, self.vault?.root == vault.root {
                draftStore = DraftStore(vault: vault)
                reloadDrafts()
                return try await startServices(index: existing, vault: vault)
            }
            let index = try openIndex(vault: vault)
            if index.wasReset {
                vault.removeAllRaw()
                log("index bol po aktualizácii vytvorený nanovo, pošta sa stiahne znova")
            }
            self.index = index
            self.vault = vault
            if index.needsDateRepair {
                // Messages stored before the lenient date parser may carry the download time as their date.
                Task {
                    let changed = (try? await index.repairDates(vault: vault)) ?? 0
                    log("dátumy opravené: \(changed) správ")
                    await reloadNow()
                }
            }
            draftStore = DraftStore(vault: vault)
            reloadDrafts()
            try await startServices(index: index, vault: vault)
        } catch {
            errorMessage = error.localizedDescription
            log("chyba: \(error)")
        }
    }

    /// Opens the index; a damaged one is put aside (`index.broken-….sqlite`) and a new one created.
    /// The mail files stay in the vault and the sync fills the new index again.
    private func openIndex(vault: MailVault) throws -> MailIndex {
        do {
            return try MailIndex(url: vault.indexURL)
        } catch {
            let text = "\(error)".lowercased()
            guard text.contains("malformed") || text.contains("not a database") || text.contains("corrupt") else { throw error }
            log("index je poškodený (\(error)), vytváram nový")
            Self.moveAside(vault.indexURL)
            showToast("Databáza bola poškodená – vytvoril som novú, pošta sa načíta znova")
            return try MailIndex(url: vault.indexURL)
        }
    }

    private static func moveAside(_ url: URL) {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-\(Int(Date().timeIntervalSince1970) % 100_000)"
        let broken = url.deletingLastPathComponent().appending(path: "index.broken-\(stamp).sqlite")
        try? FileManager.default.moveItem(at: url, to: broken)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Settings → Úložisko: a new, empty index; mail files stay and the sync fills it again.
    func rebuildIndex() async {
        guard let vault else { return }
        log("index sa vytvára nanovo")
        syncLoop?.cancel()
        for watcher in watchers.values { await watcher.stop() }
        for service in services.values { await service.disconnect() }
        index = nil
        Self.moveAside(vault.indexURL)
        self.vault = nil
        await configure()
        showToast("Databáza vytvorená nanovo, pošta sa načíta zo servera")
    }

    /// Once a day after launch: SQLite's quick check, and a copy of the settings into the vault
    /// (`.mailmule/settings-backup.json`), so a lost Mac or reset keeps accounts, rules and signatures.
    private func dailyMaintenance() {
        let key = "lastDailyMaintenance"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, let index = self.index, let vault = self.vault else { return }
            UserDefaults.standard.set(Date(), forKey: key)
            self.exportSettings(to: vault.root.appending(path: ".mailmule/settings-backup.json"), quiet: true)
            let result = (try? await index.quickCheck()) ?? "ok"
            self.log("denná kontrola databázy: \(result.prefix(200))")
            if result != "ok" {
                self.errorMessage = "Databáza pošty má chyby. Opravíte ju v Nastaveniach → Úložisko → „Vytvoriť databázu nanovo“ (pošta ostane na serveri aj v Macu)."
            }
        }
    }

    /// Creates the account services and IDLE watchers and starts the sync loop.
    private func startServices(index: MailIndex, vault: MailVault) async throws {
        if Demo.isActive { return await startDemo(index: index, vault: vault) }
        // Gmail drafts used to be indexed from All Mail; they belong to Koncepty only.
        if let paths = try? await index.removeDraftMessages(), !paths.isEmpty {
            for path in paths { try? FileManager.default.removeItem(at: vault.root.appending(path: path)) }
            log("koncepty odstránené zo zoznamu pošty: \(paths.count)")
        }
        for account in settings.accounts where !settings.disabledAccounts.contains(account.id) {
            // Read off the main thread: a Keychain permission prompt must not freeze the window.
            let id = account.id
            let stored = await Task.detached { Keychain.password(for: id) }.value
            guard let password = stored else {
                errorMessage = "Chýba heslo pre \(account.email). Doplň ho v Nastaveniach."
                syncErrors[account.id] = "Chýba heslo v kľúčenke"
                log("účet \(account.email): heslo sa nepodarilo načítať z kľúčenky")
                continue
            }
            Keychain.adoptIfNeeded(password, for: id)
            services[account.id] = AccountService(account: account, password: password, index: index, vault: vault,
                                                  policy: settings.syncPolicies[account.id] ?? .init())
            // IDLE tells us about new inbox mail right away; the periodic sync covers the other folders.
            let watcher = IdleWatcher(account: account, password: password,
                                      onChange: { [weak self] in await self?.syncAccount(id, inboxOnly: true) },
                                      onError: { [weak self] error in await self?.log("idle \(id): \(error)") })
            watchers[account.id] = watcher
            await watcher.start()
        }
        log("štart: \(settings.accounts.count) účtov, \(services.count) pripravených")
        backfillEventsIfNeeded()
        dailyMaintenance()
        Task {
            let status = await Notifier.ensureAuthorization()
            log("upozornenia v macOS: \(status == .authorized ? "povolené" : status == .denied ? "zakázané" : "\(status.rawValue)")")
        }
        observeWake()
        await reloadNow()
        snoozeTimer?.cancel()
        snoozeTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.wakeDueSnoozes()
                await self?.checkFollowUps()
                await self?.sendDueScheduled()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAll()
                await self?.sweepDelayedRules()
                await self?.syncServerDrafts()
                let minutes = await self?.settings.syncIntervalMinutes ?? 5
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
            }
        }
    }

    /// Network back: send what waits in the outbox and sync.
    private func observeNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, online != self.isOnline else { return }
                self.isOnline = online
                self.log(online ? "sieť je späť" : "bez siete")
                if online {
                    self.retryOutbox()
                    await self.syncAll()
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    /// Demo mode: services without passwords or connections, filled with made-up mail once.
    private func startDemo(index: MailIndex, vault: MailVault) async {
        for account in settings.accounts where account.email.hasSuffix(".example") {
            services[account.id] = AccountService(account: account, password: "", index: index, vault: vault)
        }
        if (try? await index.messageCounts())?.isEmpty ?? true {
            await Demo.seed(model: self, index: index, services: services)
        }
        log("demo: \(settings.accounts.count) účty, bez pripojenia")
        await reloadNow()
        Demo.showScreen(model: self)
    }

    /// After sleep the IDLE connections are dead; reconnect and catch up.
    private func observeWake() {
        observeNetwork()
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for watcher in self.watchers.values { await watcher.restart() }
                await self.syncAll()
            }
        }
    }

    /// Downloads older mail in the background, a batch at a time, until the whole history is local.
    private func startBackfill(_ accountID: String) {
        guard backfillTasks[accountID] == nil, let service = services[accountID] else { return }
        backfillTasks[accountID] = Task { [weak self] in
            var previous = Int.max
            while !Task.isCancelled {
                do {
                    let report = try await service.backfill(batch: 50)
                    guard let self else { return }
                    self.historyRemaining[accountID] = report.remainingHistory
                    await self.reloadNow()
                    // Stop when done, or when a batch made no progress (avoids looping on a broken message).
                    if report.remainingHistory == 0 || report.remainingHistory >= previous { break }
                    previous = report.remainingHistory
                } catch {
                    self?.log("história \(accountID): \(error)")
                    try? await Task.sleep(for: .seconds(60))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.backfillTasks[accountID] = nil
        }
    }

    /// Syncs one account, e.g. when IDLE reports new mail.
    func syncAccount(_ id: String, inboxOnly: Bool = false) async {
        guard !Demo.isActive, let service = services[id] else { return }
        do {
            handle(try await inboxOnly ? service.syncInbox() : service.sync(), account: service.account)
        } catch {
            recordSyncFailure(error, account: service.account)
        }
        await reloadNow()
        if let selected = selectedThreadID { await loadMessages(selected) }
    }

    private func recordSyncFailure(_ error: Error, account: Account) {
        syncErrors[account.id] = error.localizedDescription
        log("sync \(account.email) ZLYHAL: \(error.localizedDescription) [\(error)]")
    }

    private func handle(_ report: SyncReport, account: Account) {
        syncErrors[account.id] = nil
        accountLastSync[account.id] = Date()
        log("čas \(account.email): \(report.timings.joined(separator: ", "))\(report.skippedMailboxes > 0 ? "; bez zmeny: \(report.skippedMailboxes)" : "")")
        if report.inboxOnly {
            log("sync \(account.email) (Doručená): \(report.newMessages) nových, \(report.changedThreads.count) zmenených vlákien")
        } else {
            foldersByAccount[account.id] = report.folders
            historyRemaining[account.id] = report.remainingHistory
            if report.remainingHistory > 0 { startBackfill(account.id) }
            log("sync \(account.email): \(report.newMessages) nových, \(report.changedThreads.count) zmenených vlákien; priečinky: \(report.mailboxes.joined(separator: ", ")); odoslané: \(report.sentMailbox ?? "nenájdené")")
        }
        let announce = initialSyncDone.contains(account.id)
        initialSyncDone.insert(account.id)
        let incoming = report.newInboxMessages
        guard !incoming.isEmpty else { return }
        Task {
            // Rules first: they may archive the mail or keep it quiet.
            let quiet = await applyRules(toIncoming: incoming)
            // The first sync downloads existing mail; announcing it would be noise.
            guard announce else {
                log("prvá synchronizácia po spustení: \(incoming.count) nových bez upozornenia")
                return
            }
            let email = settings.accounts.count > 1 ? accountTitle(account) : nil
            for message in incoming.prefix(5) {
                if quiet.contains(message.threadID) {
                    log("upozornenie vynechané (pravidlo): \(message.subject.prefix(60))")
                } else if !shouldNotify(message) {
                    log("upozornenie vynechané (nastavenia): \(message.subject.prefix(60))")
                } else {
                    Notifier.notify(message, accountEmail: email, settings: settings)
                    log("upozornenie: \(message.from?.address ?? "?") – \(message.subject.prefix(60))")
                }
            }
        }
    }

    /// New mail notification rules: account not muted, VIP only, quiet hours.
    func shouldNotify(_ message: StoredMessage) -> Bool {
        guard settings.notifyBanners || settings.notifySound,
              !settings.mutedAccounts.contains(message.accountID) else { return false }
        if settings.notifyOnlyVIP, !AppSettings.matches(message.from?.address, settings.vipSenders) { return false }
        if settings.quietHours {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let from = settings.quietFrom, to = settings.quietTo
            let quiet = from <= to ? (now >= from && now < to) : (now >= from || now < to)
            if quiet { return false }
        }
        return true
    }

    func saveAccount(_ draft: AccountDraft, applyingPolicy: Bool = true) async {
        let account = draft.account
        if let originalID = draft.originalID, originalID != account.id {
            Keychain.deletePassword(for: originalID)
        }
        Keychain.setPassword(draft.password, for: account.id)
        if let originalID = draft.originalID, originalID != account.id { settings.accountLabels[originalID] = nil }
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        settings.accountLabels[account.id] = label.isEmpty ? nil : label
        var accounts = settings.accounts.filter { $0.id != draft.originalID && $0.id != account.id }
        accounts.append(account)
        settings.accounts = accounts
        let previousPolicy = settings.syncPolicies[account.id] ?? .init()
        settings.syncPolicies[account.id] = draft.policy
        started = true
        await configure()
        if applyingPolicy && draft.originalID != nil && draft.policy != previousPolicy {
            applyPolicy(accountID: account.id)
        }
    }

    /// Frees disk space after the sync policy got stricter: removes mail older than the history limit
    /// and attachment contents (both stay on the server).
    func applyPolicy(accountID: String) {
        guard let service = services[accountID] else { return }
        let policy = settings.syncPolicies[accountID] ?? .init()
        maintenance = "Uvoľňujem miesto…"
        Task {
            do {
                let pruned = try await service.pruneHistory()
                var freed = (messages: 0, bytes: 0)
                if policy.attachments == .onDemand { freed = try await service.stripAttachments() }
                let size = ByteCountFormatter.string(fromByteCount: Int64(freed.bytes), countStyle: .file)
                log("pravidlá \(accountID): odstránených \(pruned) starších správ, prílohy z \(freed.messages) správ (\(size))")
                showToast("Uvoľnené: \(pruned) starších správ, \(size) príloh")
            } catch {
                errorMessage = error.localizedDescription
                log("pravidlá chyba: \(error)")
            }
            maintenance = nil
            await reloadNow()
        }
    }

    func removeAccount(_ id: String) async {
        Keychain.deletePassword(for: id)
        settings.accounts.removeAll { $0.id == id }
        settings.syncPolicies[id] = nil
        await configure()
        await removeLocalMail(accountID: id)
        await reloadNow()
    }

    /// Deletes an account's downloaded mail and notes and downloads it again under the current policy.
    func resetAccount(_ id: String) async {
        backfillTasks[id]?.cancel()
        backfillTasks[id] = nil
        await removeLocalMail(accountID: id)
        historyRemaining[id] = nil
        initialSyncDone.remove(id)
        log("účet \(id): stiahnutá pošta vymazaná, sťahujem odznova")
        showToast("Stiahnutá pošta vymazaná, sťahujem odznova")
        await reloadNow()
        await syncAccount(id)
    }

    private func removeLocalMail(accountID: String) async {
        guard let index, let vault else { return }
        do {
            let notes = try await index.removeAccount(accountID)
            vault.removeAccountFiles(accountID, notes: notes)
        } catch {
            errorMessage = error.localizedDescription
            log("mazanie pošty chyba: \(error)")
        }
    }

    /// Syncs all accounts in parallel; one failing account does not hold up the others.
    func syncAll() async {
        guard !Demo.isActive else { return }
        guard !isSyncing else {
            Self.logger.notice("syncAll: already syncing")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        Self.logger.notice("syncAll: \(self.services.count) services")
        // One task per account so they sync in parallel. Each task records its own outcome on the
        // main actor; the tasks return nothing (returning a tuple with a Result from a Task crashed in
        // optimized builds with Swift 6.3).
        let tasks = services.values.map { service in
            Task { @MainActor [weak self] in
                do {
                    let report = try await service.sync()
                    self?.handle(report, account: service.account)
                } catch {
                    self?.recordSyncFailure(error, account: service.account)
                }
            }
        }
        for task in tasks { await task.value }
        Self.logger.notice("syncAll: \(tasks.count) accounts done")
        if syncErrors.isEmpty && !tasks.isEmpty { lastSync = Date() }
        await reloadNow()
        if let id = selectedThreadID { await loadMessages(id) }
    }

    // MARK: - Threads

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { await reloadNow() }
    }

    func reloadNow() async {
        guard let index else {
            threads = []
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        do {
            // Search always looks through all local mail, like Superhuman.
            let hidden = Set(pendingActions.filter(\.hidden).flatMap { $0.threads.map(\.thread.id) })
            threads = try await index.threads(filter: query.isEmpty ? filter : .all, accountID: accountScope,
                                              search: query.isEmpty ? nil : query, options: listView.options)
                .filter { !hidden.contains($0.id) }
            // Tags are global: the same names and counts in every account view.
            snoozes = try await index.snoozes()
            followUps = try await index.followUps()
            allTags = try await index.allTags()
            tagCounts = try await index.tagCounts()
            unreadByAccount = try await index.unreadInboxThreadsByAccount()
            var perFolder: [String: [String: Int]] = [:]
            for account in settings.accounts {
                perFolder[account.id] = try await index.unreadThreadsByMailbox(account: account.id)
            }
            folderUnread = perFolder
            inboxUnread = unreadByAccount.values.reduce(0, +)
            Notifier.setDockBadge(settings.dockBadge ? inboxUnread : 0)
        } catch {
            errorMessage = error.localizedDescription
            log("chyba: \(error)")
        }
    }

    private func loadSelectedThread() {
        guard let id = selectedThreadID else {
            messages = []
            return
        }
        Task {
            await loadMessages(id)
            await markSeen(id)
        }
    }

    private func loadMessages(_ id: String) async {
        let loaded = (try? await index?.messages(inThread: id)) ?? []
        if selectedThreadID == id { messages = loaded }
        await loadStoredSummary(id, latestKey: loaded.last?.key)
    }

    /// A summary made earlier shows right away; it is marked out of date when newer mail arrived.
    private func loadStoredSummary(_ id: String, latestKey: String?) async {
        guard summarizing != id, let stored = try? await index?.summary(threadID: id) else { return }
        summaries[id] = stored.text
        summaryOutdated[id] = latestKey.map { $0 != stored.latestKey } ?? false
    }

    private func markSeen(_ id: String) async {
        guard let thread = threads.first(where: { $0.id == id }), thread.isUnread,
              let service = services[thread.accountID] else { return }
        do {
            try await service.markThreadSeen(id)
            await reloadNow()
        } catch {
            errorMessage = error.localizedDescription
            log("chyba: \(error)")
        }
    }

    func moveSelection(_ delta: Int) {
        guard !threads.isEmpty else { return }
        let anchor = selectedThreadID ?? (delta > 0 ? targetThreadIDs.last : targetThreadIDs.first)
        let current = threads.firstIndex { $0.id == anchor }
        let next = current.map { min(max($0 + delta, 0), threads.count - 1) } ?? 0
        selectedThreadID = threads[next].id
    }

    func archiveSelected() {
        move(targetThreadIDs, to: .archive)
    }

    /// Moves the selected threads to the Trash; in the Trash it deletes them for good.
    func deleteSelected() {
        move(targetThreadIDs, to: .trash)
    }

    /// Moves the selected threads from Archive, Trash or a folder back to the inbox.
    func moveSelectedToInbox() {
        move(targetThreadIDs, to: .inbox)
    }

    func move(_ threadID: String, to target: ThreadFilter) {
        move([threadID], to: target)
    }

    /// Moves threads to Inbox, Archive or Trash (keys, toolbar, context menu, drag and drop).
    /// Moving to Trash while viewing the Trash deletes for good.
    func move(_ threadIDs: [String], to target: ThreadFilter) {
        guard !threadIDs.isEmpty else { return }
        let viewingSearch = !searchText.isEmpty
        switch target {
        case .inbox:
            guard filter != .inbox || viewingSearch else { return }
            perform(.moveToInbox, threadIDs: threadIDs)
        case .archive:
            guard filter != .archive || viewingSearch else { return }
            perform(.archive, threadIDs: threadIDs)
        case .trash:
            perform(filter == .trash && !viewingSearch ? .deleteForever : .delete, threadIDs: threadIDs)
        case .sent, .all, .starred, .tag, .folder, .junk, .snoozed, .followUps:
            return
        }
    }

    func move(_ threadID: String, toFolder folder: FolderInfo) {
        move([threadID], toFolder: folder)
    }

    /// Moves threads into a server folder (`v`, drag and drop, context menu).
    func move(_ threadIDs: [String], toFolder folder: FolderInfo) {
        guard !threadIDs.isEmpty, filter != .folder(folder.name) || !searchText.isEmpty else { return }
        perform(.moveToFolder(folder.name, folder.displayName), threadIDs: threadIDs)
    }

    /// Folders of the account the threads belong to; none when they span several accounts.
    func folders(forThreads threadIDs: [String]) -> [FolderInfo] {
        let accounts = Set(threadIDs.compactMap { id in threads.first { $0.id == id }?.accountID })
        guard accounts.count == 1, let accountID = accounts.first else { return [] }
        return foldersByAccount[accountID] ?? []
    }

    func folders(forThread threadID: String) -> [FolderInfo] {
        folders(forThreads: [threadID])
    }

    func folderName(_ mailbox: String) -> String {
        foldersByAccount.values.joined().first { $0.name == mailbox }?.displayName ?? mailbox
    }

    /// The account the sidebar is showing, or the only account.
    var focusedAccount: Account? {
        accountScope.flatMap(account) ?? (settings.accounts.count == 1 ? settings.accounts.first : nil)
    }

    func isGmail(_ account: Account) -> Bool {
        account.imapHost.hasSuffix("gmail.com")
    }

    /// Accounts whose mail the current view shows.
    var accountsInScope: [Account] {
        accountScope.flatMap(account).map { [$0] } ?? settings.accounts
    }

    func createFolder(_ name: String, accountID: String) {
        guard let service = services[accountID] else { return }
        Task {
            do {
                try await service.createFolder(name)
                showToast("Priečinok „\(name)“ vytvorený")
                await reloadNow()
            } catch {
                errorMessage = "Priečinok sa nepodarilo vytvoriť: \(error.localizedDescription)"
                log("nový priečinok chyba: \(error)")
            }
        }
    }

    func openFolderPicker(_ threadIDs: [String]? = nil) {
        let ids = threadIDs ?? targetThreadIDs
        guard !ids.isEmpty else { return }
        folderPickerThreadIDs = ids
    }

    // MARK: - Snooze

    func openSnoozePicker(_ threadIDs: [String]? = nil) {
        let ids = threadIDs ?? targetThreadIDs
        guard !ids.isEmpty else { return }
        snoozePickerThreadIDs = ids
    }

    /// Takes threads out of the inbox until `date` (undoable for a few seconds like archiving).
    func snooze(_ threadIDs: [String], until date: Date) {
        guard !threadIDs.isEmpty, date > Date() else { return }
        perform(.snooze(date), threadIDs: threadIDs)
    }

    func followUpCount(account: String?) -> Int {
        followUps.values.filter { account == nil || $0.accountID == account }.count
    }

    func snoozeCount(account: String?) -> Int {
        guard let account else { return snoozes.count }
        return snoozes.keys.filter { $0.hasPrefix(account + ":") }.count
    }

    /// Brings back threads whose snooze time has come, with a notification.
    private func wakeDueSnoozes() async {
        guard let index, let due = try? await index.dueSnoozes(), !due.isEmpty else { return }
        for item in due {
            guard let service = services[item.account] else { continue }
            do {
                try await service.wakeSnoozed(item.threadID)
                if let message = try await index.messages(inThread: item.threadID).last {
                    Notifier.notify(message, accountEmail: "Pripomienka · odložená správa", settings: settings)
                }
                log("odloženie skončilo: \(item.threadID)")
            } catch {
                log("odloženie chyba: \(error)")
            }
        }
        await reloadNow()
    }

    // MARK: - Stars, read state, tags

    private func services(for threadIDs: [String]) -> [(index: Int, thread: ThreadSummary, service: AccountService)] {
        threadIDs.compactMap { id in
            guard let index = threads.firstIndex(where: { $0.id == id }),
                  let service = services[threads[index].accountID] else { return nil }
            return (index, threads[index], service)
        }
    }

    /// Stars or unstars threads (`s`): stars all of them unless all are starred already.
    func toggleStar(_ threadIDs: [String]? = nil) {
        let items = services(for: threadIDs ?? targetThreadIDs)
        guard !items.isEmpty else { return }
        let starred = !items.allSatisfy(\.thread.flagged)
        for item in items { threads[item.index].flagged = starred }
        Task {
            for item in items {
                do {
                    try await item.service.setStarred(item.thread.id, starred)
                } catch {
                    errorMessage = error.localizedDescription
                    log("hviezdička chyba: \(error)")
                }
            }
            showToast((starred ? "Označené hviezdičkou" : "Hviezdička odstránená") + (items.count > 1 ? " (\(items.count))" : ""))
            await reloadNow()
        }
    }

    /// Marks threads read or unread (`u`): read when any of them is unread, otherwise unread.
    func toggleRead(_ threadIDs: [String]? = nil) {
        let items = services(for: threadIDs ?? targetThreadIDs)
        guard !items.isEmpty else { return }
        let seen = items.contains { $0.thread.isUnread }
        for item in items { threads[item.index].unreadCount = seen ? 0 : max(1, item.thread.messageCount) }
        Task {
            for item in items {
                do {
                    try await item.service.setSeen(item.thread.id, seen)
                } catch {
                    errorMessage = error.localizedDescription
                    log("prečítané chyba: \(error)")
                }
            }
            showToast((seen ? "Označené ako prečítané" : "Označené ako neprečítané") + (items.count > 1 ? " (\(items.count))" : ""))
            await reloadNow()
        }
    }

    /// Finder color number of a tag (0 = no color).
    func tagColor(_ tag: String) -> Int {
        tagCatalog.color(for: tag)
    }

    /// Picks a Finder color for a tag and re-tags the thread notes so Finder shows the new color.
    func setTagColor(_ tag: String, _ color: Int) {
        settings.tagColors[tag] = color
        tagCatalog.setOverrides(settings.tagColors)
        let services = Array(services.values)
        Task {
            for service in services { try? await service.refreshFinderTags(forTag: tag) }
        }
    }

    /// Tags offered in menus: Finder's favourites, then the other tags used in mail.
    var menuTags: [String] {
        tagCatalog.menuTags(inUse: allTags)
    }

    /// Removes the tag from every thread that has it (in all accounts).
    func removeTagEverywhere(_ tag: String) {
        guard let index else { return }
        Task {
            let tagged = (try? await index.threads(filter: .tag(tag))) ?? []
            for thread in tagged {
                guard let service = services[thread.accountID] else { continue }
                do {
                    try await service.setTag(tag, false, threadID: thread.id)
                } catch {
                    log("štítok chyba: \(error)")
                }
            }
            settings.tagColors[tag] = nil
            if case .tag(tag) = filter { filter = .inbox }
            showToast("Štítok „\(tag)“ odstránený")
            await reloadNow()
        }
    }

    func openTagPicker(_ threadIDs: [String]? = nil) {
        let ids = threadIDs ?? targetThreadIDs
        guard !ids.isEmpty else { return }
        tagPickerThreadIDs = ids
    }

    /// Tags every one of the threads has (compared case-insensitively).
    func commonTags(_ threadIDs: [String]) -> [String] {
        let tagSets = threadIDs.compactMap { id in threads.first { $0.id == id }.map { Set($0.tags.map(Tags.fold)) } }
        guard let first = tagSets.first else { return [] }
        let common = tagSets.dropFirst().reduce(first) { $0.intersection($1) }
        return (threads.first { $0.id == threadIDs.first }?.tags ?? []).filter { common.contains(Tags.fold($0)) }
    }

    /// The spelling already in use for a tag ("práca" typed, "Práca" exists → "Práca").
    func canonicalTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        return (allTags + menuTags).first { Tags.fold($0) == Tags.fold(trimmed) } ?? trimmed
    }

    func threadCount(forTag tag: String) -> Int? {
        tagCounts[Tags.fold(tag)]
    }

    func setTag(_ tag: String, _ on: Bool, threadID: String) {
        setTag(tag, on, threadIDs: [threadID])
    }

    func setTag(_ tag: String, _ on: Bool, threadIDs: [String]) {
        let tag = canonicalTag(tag)
        let items = services(for: threadIDs)
        guard !tag.isEmpty, !items.isEmpty else { return }
        let key = Tags.fold(tag)
        for item in items {
            let others = item.thread.tags.filter { Tags.fold($0) != key }
            threads[item.index].tags = on ? others + [tag] : others
        }
        if on && !allTags.contains(where: { Tags.fold($0) == key }) { allTags.append(tag) }
        Task {
            for item in items {
                do {
                    try await item.service.setTag(tag, on, threadID: item.thread.id)
                } catch {
                    errorMessage = error.localizedDescription
                    log("štítok chyba: \(error)")
                }
            }
            await reloadNow()
            if let selected = selectedThreadID, threadIDs.contains(selected) { await loadMessages(selected) }
        }
    }

    /// Hides the threads right away and runs the server action after a few seconds,
    /// so it can still be undone (like Superhuman).
    private func perform(_ kind: PendingAction.Kind, threadIDs: [String]) {
        let items = threadIDs.compactMap { id in threads.firstIndex { $0.id == id }.map { (thread: threads[$0], position: $0) } }
        guard !items.isEmpty else { return }
        // Hide the threads only when they no longer belong in the current view.
        let inFolder = if case .folder = filter { true } else { false }
        let hides = switch kind {
        case .archive: filter == .inbox || filter == .trash || filter == .junk || inFolder
        case .moveToInbox: filter == .archive || filter == .trash || filter == .junk || filter == .snoozed || inFolder
        case .snooze: filter != .snoozed
        case .delete, .deleteForever: true
        case .moveToFolder(let mailbox, _): filter != .folder(mailbox)
        }
        if hides {
            let removed = Set(items.map(\.thread.id))
            let firstPosition = items.map(\.position).min() ?? 0
            let wasSelected = selection.contains { removed.contains($0) } || selectedThreadID.map(removed.contains) == true
            threads.removeAll { removed.contains($0.id) }
            if wasSelected {
                selectedThreadID = threads.isEmpty ? nil : threads[min(firstPosition, threads.count - 1)].id
            }
        }
        let actionID = UUID()
        let affected = items.map(\.thread)
        let task = Task { [weak self] in
            try? await Task.sleep(for: PendingAction.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.commit(actionID, kind: kind, threads: affected)
        }
        pendingActions.append(PendingAction(id: actionID, kind: kind, threads: items, hidden: hides, task: task))
    }

    private func commit(_ actionID: UUID, kind: PendingAction.Kind, threads affected: [ThreadSummary]) async {
        for thread in affected {
            guard let service = services[thread.accountID] else { continue }
            do {
                switch kind {
                case .archive:
                    if settings.markReadOnArchive && thread.isUnread { try await service.setSeen(thread.id, true) }
                    try await service.archiveThread(thread.id)
                    // A reminder that already came back is dealt with once the thread is archived again.
                    if followUps[thread.id]?.fired == true { try await index?.removeFollowUp(threadID: thread.id) }
                case .delete: try await service.deleteThread(thread.id)
                case .deleteForever: try await service.deleteThread(thread.id, permanently: true)
                case .moveToInbox: try await service.moveThreadToInbox(thread.id)
                case .moveToFolder(let mailbox, _): try await service.moveThread(thread.id, toMailbox: mailbox)
                case .snooze(let date): try await service.snoozeThread(thread.id, until: date)
                }
            } catch {
                errorMessage = error.localizedDescription
                log("chyba (\(kind.title)): \(error)")
            }
        }
        pendingActions.removeAll { $0.id == actionID }
        await reloadNow()
    }

    /// Runs pending actions immediately, e.g. when the app quits inside the undo window.
    func flushPendingActions() async {
        await flushPendingSend()
        let actions = pendingActions
        for action in actions {
            action.task.cancel()
            await commit(action.id, kind: action.kind, threads: action.threads.map(\.thread))
        }
    }

    /// Cancels the most recent action that has not reached the server yet and puts the threads back.
    func undoLast() {
        if pendingSend != nil {
            undoSend()
            return
        }
        guard let action = pendingActions.popLast() else { return }
        action.task.cancel()
        if action.hidden {
            for item in action.threads.sorted(by: { $0.position < $1.position })
            where !threads.contains(where: { $0.id == item.thread.id }) {
                threads.insert(item.thread, at: min(item.position, threads.count))
            }
        }
        selection = Set(action.threads.map(\.thread.id))
        showToast("Vrátené")
    }

    // MARK: - Messages

    /// People in a thread for the list row: the other side only; "Ja" when you are the only sender.
    func otherParticipants(_ thread: ThreadSummary) -> [String] {
        let own = Set(settings.accounts.map { $0.email.lowercased() })
        let others = zip(thread.participants, thread.participantAddresses + Array(repeating: "", count: max(0, thread.participants.count - thread.participantAddresses.count)))
            .filter { !own.contains($0.1) }
            .map(\.0)
        return others.isEmpty ? ["Ja"] : others
    }

    func isOwn(_ address: EmailAddress?) -> Bool {
        guard let address else { return false }
        return settings.accounts.contains { $0.email.caseInsensitiveCompare(address.address) == .orderedSame }
    }

    func mime(for message: StoredMessage) -> MIMEMessage? {
        if let cached = mimeCache[message.key] { return cached }
        guard let vault, let data = try? vault.readRaw(message.rawPath) else { return nil }
        let mime = MIMEMessage(data: data)
        mimeCache[message.key] = mime
        return mime
    }

    /// Attachments of a message with their sizes (also for ones still on the server).
    func attachmentInfo(for message: StoredMessage) -> [Attachment] {
        mime(for: message)?.attachments ?? message.attachments.map { Attachment(filename: $0, mimeType: "application/octet-stream", size: 0) }
    }

    // MARK: - Images in messages

    /// Messages whose internet images were loaded once in this session.
    private var remoteImagesAllowed: Set<String> = []
    /// Resolving inline images re-encodes them, so the result is kept per message.
    private var displayCache: [String: DisplayHTML] = [:]

    private var trackerCache: [String: (html: String, removed: Int)] = [:]

    /// The HTML to show and how many tracking pixels were dropped from it (only when internet images load).
    func renderedHTML(for display: DisplayHTML, key: String, allowRemote: Bool) -> (html: String, trackers: Int) {
        guard allowRemote, settings.blockTrackers, display.hasRemoteImages else { return (display.html, 0) }
        if let cached = trackerCache[key] { return (cached.html, cached.removed) }
        let stripped = TrackerFilter.strip(display.html)
        trackerCache[key] = stripped
        return (stripped.html, stripped.removed)
    }

    func displayHTML(for message: StoredMessage) -> DisplayHTML? {
        if let cached = displayCache[message.key] { return cached }
        guard let display = mime(for: message)?.displayHTML else { return nil }
        displayCache[message.key] = display
        return display
    }

    private var inlineImageDownloads: Set<String> = []

    func remoteImagesAllowed(for message: StoredMessage) -> Bool {
        if settings.loadRemoteImages || remoteImagesAllowed.contains(message.key) || isOwn(message.from) { return true }
        return AppSettings.matches(message.from?.address, settings.trustedImageSenders)
    }

    /// "Načítať obrázky": for this message, or (`always`) for everything from the sender.
    func loadRemoteImages(for message: StoredMessage, always: Bool) {
        remoteImagesAllowed.insert(message.key)
        if always, let sender = message.from?.address.lowercased(), !settings.trustedImageSenders.contains(sender) {
            settings.trustedImageSenders.append(sender)
        }
    }

    func untrustImages(from address: String) {
        settings.trustedImageSenders.removeAll { $0 == address.lowercased() }
    }

    /// Inline images (logos, screenshots) left on the server with "attachments on demand" are part of
    /// the message itself, so they are fetched as soon as it is shown.
    func downloadInlineImages(for message: StoredMessage) {
        guard !inlineImageDownloads.contains(message.key) else { return }
        inlineImageDownloads.insert(message.key)
        Task {
            do {
                try await completeIfPartial(message, announce: false)
            } catch {
                log("vložené obrázky \(message.key): \(error)")
            }
        }
    }

    /// Downloads the whole message when it was stored without attachments.
    private func completeIfPartial(_ message: StoredMessage, announce: Bool = true) async throws {
        guard mime(for: message)?.isPartial == true, let service = services[message.accountID] else { return }
        if announce { showToast("Sťahujem prílohy…") }
        try await service.materialize(key: message.key)
        mimeCache[message.key] = nil
        displayCache[message.key] = nil
        trackerCache[message.key] = nil
    }

    func openAttachment(_ filename: String, in message: StoredMessage) {
        Task {
            do {
                try await completeIfPartial(message)
                writeAndOpenAttachment(filename, in: message)
            } catch {
                errorMessage = "Prílohu sa nepodarilo stiahnuť: \(error.localizedDescription)"
                log("príloha chyba: \(error)")
            }
        }
    }

    // MARK: Quick Look

    /// Quick Look over the message's attachments, starting at `filename` (arrows move between them).
    func previewAttachments(in message: StoredMessage, startingAt filename: String? = nil) {
        Task {
            do {
                try await completeIfPartial(message)
                let urls = try writeAttachments(of: message)
                guard !urls.isEmpty else { return }
                let start = urls.firstIndex { $0.lastPathComponent == filename } ?? 0
                let id = UUID().uuidString
                viewerSessions[id] = ViewerSession(urls: urls, index: start)
                windowRequest = .viewer(id)
            } catch {
                errorMessage = "Prílohu sa nepodarilo stiahnuť: \(error.localizedDescription)"
            }
        }
    }

    /// Space in the list or thread: preview the attachments of the newest message that has any.
    func previewSelectedAttachments() -> Bool {
        guard let message = messages.last(where: { !$0.attachments.isEmpty }) else { return false }
        previewAttachments(in: message)
        return true
    }

    /// "Uložiť ako…" or straight into Downloads.
    func saveAttachment(_ filename: String, in message: StoredMessage, toDownloads: Bool) {
        Task {
            do {
                try await completeIfPartial(message)
                guard let source = try writeAttachments(of: message).first(where: { $0.lastPathComponent == filename }) else { return }
                var target: URL
                if toDownloads {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    target = downloads.appending(path: filename)
                    var counter = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        let base = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
                        target = downloads.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                        counter += 1
                    }
                } else {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = filename
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    target = url
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                showToast("Uložené: \(target.lastPathComponent)")
                if toDownloads { NSWorkspace.shared.activateFileViewerSelecting([target]) }
            } catch {
                errorMessage = "Prílohu sa nepodarilo uložiť: \(error.localizedDescription)"
            }
        }
    }

    /// Writes every attachment of a message to the temporary folder (cleared at launch) and returns the files.
    private func writeAttachments(of message: StoredMessage) throws -> [URL] {
        guard let mime = mime(for: message) else { return [] }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Mailmule/\(message.key)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var used = Set<String>()
        return try mime.root.leaves.filter { $0.isAttachment && $0.stubSize == nil }.map { part in
            var name = (part.filename ?? "príloha").replacingOccurrences(of: "/", with: "-")
            if !used.insert(name).inserted { name = "\(used.count) \(name)"; used.insert(name) }
            let url = dir.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { try part.decodedBody.write(to: url) }
            return url
        }
    }

    /// Previews and opened attachments from earlier sessions.
    static func clearAttachmentCache() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "Mailmule"))
    }

    private func writeAndOpenAttachment(_ filename: String, in message: StoredMessage) {
        guard let part = mime(for: message)?.root.leaves.first(where: { $0.isAttachment && ($0.filename ?? "príloha") == filename }) else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Mailmule/\(message.key)")
        let url = dir.appending(path: filename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try part.decodedBody.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
            log("chyba: \(error)")
        }
    }

    // MARK: - Compose

    /// New message from the account being viewed, or the first account in the unified view.
    /// Reloads the autocomplete addresses (new mail since the last compose); asks for Contacts access once.
    func refreshAddressBook() {
        guard let index else { return }
        let own = settings.accounts.map(\.email)
        let contacts = settings.suggestFromContacts
        Task { await addressBook.load(index: index, ownAddresses: own, contacts: contacts) }
    }

    func composeNew() {
        guard let accountID = defaultSenderID else { return }
        presentCompose(ComposeDraft(accountID: accountID, body: signatureBlock(accountID, kind: .new)))
    }

    /// The primary account if it still exists, otherwise the first one.
    var primaryAccountID: String? {
        settings.primaryAccountID.flatMap { id in account(id)?.id } ?? settings.accounts.first?.id
    }

    /// Sender of a new message, by the "Predvolený odosielateľ" setting.
    var defaultSenderID: String? {
        switch settings.defaultSender {
        case .currentAccount: accountScope ?? primaryAccountID
        case .primary: primaryAccountID
        }
    }

    /// The account's signature as it appears in a message body ("-- " line, the usual delimiter); empty without one.
    func signatureBlock(_ accountID: String, kind: ComposeKind) -> String {
        let placed = switch settings.signaturePlacement {
        case .all: true
        case .newAndReplies: kind != .forward
        case .newOnly: kind == .new
        case .never: false
        }
        guard placed else { return "" }
        let signature = (settings.signatures[accountID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return signature.isEmpty ? "" : "\n\n-- \n\(signature)"
    }

    /// The account's own name if it has one, otherwise its address.
    func accountTitle(_ account: Account) -> String {
        let label = (settings.accountLabels[account.id] ?? "").trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? account.email : label
    }

    func hasAccountLabel(_ account: Account) -> Bool {
        !(settings.accountLabels[account.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The connection of an account (for code outside this file).
    func service(for accountID: String) -> AccountService? {
        services[accountID]
    }

    func account(_ id: String) -> Account? {
        settings.accounts.first { $0.id == id }
    }

    /// Stable color per account, used to tell accounts apart in the unified inbox.
    func accountColor(_ id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        let index = settings.accounts.firstIndex { $0.id == id } ?? 0
        return palette[index % palette.count]
    }

    /// `thread`: the messages of a thread shown in its own window; nil for the selected thread.
    func reply(all: Bool, in thread: [StoredMessage]? = nil) {
        let source = thread ?? messages
        let ids = Set(source.compactMap(\.messageID))
        if let existing = drafts.first(where: { $0.inReplyTo.map(ids.contains) ?? false }) {
            presentCompose(existing, fromWindow: thread != nil)
            return
        }
        if let draft = replyDraft(all: all, from: source) { presentCompose(draft, fromWindow: thread != nil) }
    }

    /// The editor: a sheet over the main window, or its own window (setting, or when asked from another window).
    func presentCompose(_ draft: ComposeDraft, fromWindow: Bool = false) {
        if settings.composeInWindow || fromWindow {
            windowDrafts[draft.id] = draft
            windowRequest = .compose(draft.id)
        } else {
            compose = draft
        }
    }

    /// Sends a reply written in the quick reply field under the thread; the original is quoted below it.
    func quickReply(_ text: String, archive: Bool, followUp: Date? = nil) async -> Bool {
        guard var draft = replyDraft(all: false, from: messages) else { return false }
        draft.body = text + draft.body
        return await send(draft, archive: archive, followUp: followUp)
    }

    /// Opens the full editor with the quick reply text, e.g. to add attachments or formatting.
    func expandQuickReply(_ text: String) {
        guard var draft = replyDraft(all: false, from: messages) else { return }
        draft.body = text + draft.body
        presentCompose(draft)
    }

    private func replyDraft(all: Bool, from messages: [StoredMessage]) -> ComposeDraft? {
        guard let last = messages.last(where: { !isOwn($0.from) }) ?? messages.last else { return nil }
        let accountID = settings.accounts.contains { $0.id == last.accountID } ? last.accountID : settings.accounts.first?.id ?? ""
        let mime = mime(for: last)

        var to: [EmailAddress]
        if isOwn(last.from) {
            to = last.to
        } else if let replyTo = mime?.replyTo, !replyTo.isEmpty {
            to = replyTo
        } else {
            to = [last.from].compactMap { $0 }
        }
        var cc: [EmailAddress] = []
        if all {
            let taken = Set(to.map { $0.address.lowercased() })
            cc = (last.to + last.cc).filter { !isOwn($0) && !taken.contains($0.address.lowercased()) }
        }

        let subject = last.subject.lowercased().hasPrefix("re:") ? last.subject : "Re: \(last.subject)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy 'o' HH:mm"
        let sender = last.from.map { "\($0.displayName) <\($0.address)>" } ?? "odosielateľ"
        let quoted = (mime?.bestText ?? last.bodyText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")

        return ComposeDraft(
            accountID: accountID,
            to: to.map(Self.fieldValue).joined(separator: ", "),
            cc: cc.map(Self.fieldValue).joined(separator: ", "),
            subject: subject,
            body: signatureBlock(accountID, kind: .reply) + "\n\nDňa \(formatter.string(from: last.date)) \(sender) napísal(a):\n\(quoted)",
            inReplyTo: last.messageID,
            references: last.references + [last.messageID].compactMap { $0 }
        )
    }

    /// Forwards the latest message of the thread together with its attachments.
    func forward(in thread: [StoredMessage]? = nil) {
        guard let last = (thread ?? messages).last else { return }
        // Forwarding includes the attachments, so complete a message stored without them first.
        Task {
            do {
                try await completeIfPartial(last)
                composeForward(last, fromWindow: thread != nil)
            } catch {
                errorMessage = "Prílohy sa nepodarilo stiahnuť: \(error.localizedDescription)"
            }
        }
    }

    private func composeForward(_ last: StoredMessage, fromWindow: Bool) {
        guard let accountID = settings.accounts.first?.id else { return }
        let mime = mime(for: last)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy 'o' HH:mm"
        let header = [
            "---------- Preposlaná správa ----------",
            "Od: \(last.from.map { "\($0.displayName) <\($0.address)>" } ?? "")",
            "Dátum: \(formatter.string(from: last.date))",
            "Predmet: \(last.subject)",
            "Komu: \(last.to.map(\.address).joined(separator: ", "))",
        ].joined(separator: "\n")
        let attachments = mime?.root.leaves.filter(\.isAttachment).map {
            OutgoingAttachment(filename: $0.filename ?? "príloha", mimeType: $0.mimeType, data: $0.decodedBody)
        } ?? []
        let subject = last.subject.lowercased().hasPrefix("fwd:") ? last.subject : "Fwd: \(last.subject.baseSubject)"
        let fromAccount = settings.accounts.contains { $0.id == last.accountID } ? last.accountID : accountID
        presentCompose(ComposeDraft(
            accountID: fromAccount,
            subject: subject,
            body: signatureBlock(fromAccount, kind: .forward) + "\n\n\(header)\n\n\(mime?.bestText ?? last.bodyText)",
            attachments: attachments
        ), fromWindow: fromWindow)
    }

    /// `archive`: archive the replied thread when sent from the Inbox; nil follows the "archiveOnReply" setting.
    /// With "zrušiť odoslanie" on, the message waits a few seconds and can still be taken back.
    func send(_ draft: ComposeDraft, archive: Bool? = nil, followUp: Date? = nil, delayed: Bool = true) async -> Bool {
        guard settings.accounts.contains(where: { $0.id == draft.accountID }), services[draft.accountID] != nil else {
            errorMessage = "Účet nie je pripravený."
            return false
        }
        guard !AddressParser.parseList(draft.to).isEmpty else {
            errorMessage = "Doplň aspoň jedného príjemcu."
            return false
        }
        let delay = settings.undoSendSeconds
        guard delayed, delay > 0 else { return await deliver(draft, archive: archive, followUp: followUp) }
        // Only one message waits at a time; an earlier one goes out now.
        await flushPendingSend()
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.pendingSend?.id == id else { return }
            self.pendingSend = nil
            if await !self.deliver(draft, archive: archive, followUp: followUp) {
                // Keep the text: back into the editor so nothing is lost.
                self.presentCompose(draft)
            }
        }
        pendingSend = PendingSend(id: id, draft: draft, archive: archive, followUp: followUp, deadline: Date().addingTimeInterval(Double(delay)), task: task)
        return true
    }

    /// "Vrátiť": the waiting message is not sent and opens in the editor again.
    func undoSend() {
        guard let pending = pendingSend else { return }
        pending.task.cancel()
        pendingSend = nil
        presentCompose(pending.draft)
        showToast("Odoslanie zrušené")
    }

    /// Sends a waiting message right away (another send, or quitting the app).
    func flushPendingSend() async {
        guard let pending = pendingSend else { return }
        pending.task.cancel()
        pendingSend = nil
        _ = await deliver(pending.draft, archive: pending.archive, followUp: pending.followUp)
    }

    private func deliver(_ draft: ComposeDraft, archive: Bool?, followUp: Date?) async -> Bool {
        guard let account = settings.accounts.first(where: { $0.id == draft.accountID }),
              let service = services[draft.accountID] else {
            errorMessage = "Účet nie je pripravený."
            return false
        }
        let to = AddressParser.parseList(draft.to)
        var message = Draft(from: account.address, to: to, cc: AddressParser.parseList(draft.cc),
                            subject: draft.subject, markdown: draft.body,
                            inReplyTo: draft.inReplyTo, references: draft.references,
                            attachments: draft.attachments)
        message.plainTextOnly = settings.messageFormat == .plain
        do {
            let result = try await service.send(message)
            let threadID = result.threadID
            if let followUp {
                try? await index?.setFollowUp(threadID: threadID, account: account.id, due: followUp, since: Date())
                showToast("Odoslané · pripomenie sa \(SnoozeOption.describe(followUp)), ak neodpovie")
            } else {
                showToast("Odoslané")
            }
            discardDraft(draft.id)
            await reloadNow()
            if selectedThreadID == threadID { await loadMessages(threadID) }
            if draft.inReplyTo != nil, archive ?? settings.archiveOnReply, filter == .inbox, searchText.isEmpty,
               threads.contains(where: { $0.id == threadID }) {
                move([threadID], to: .archive)
            }
            // The message is already delivered and shown; the server copy can wait for a running sync.
            Task {
                do {
                    try await service.copyToSent(result.raw)
                } catch {
                    log("odoslané, ale kópia do Odoslaných zlyhala: \(error)")
                    errorMessage = "Správa bola odoslaná, ale jej kópiu sa nepodarilo uložiť do priečinka Odoslané na serveri: \(error.localizedDescription)"
                }
            }
            return true
        } catch where SMTPClient.isRetryable(error) {
            log("odoslanie zlyhalo (skúsim znova): \(error)")
            return queueOutbox(draft, error: error)
        } catch {
            errorMessage = Self.friendly(error)
            log("chyba: \(error)")
            if var failed = drafts.first(where: { $0.id == draft.id && $0.outbox }) {
                // Was waiting in the outbox: back to Koncepty with the reason.
                failed.outbox = false
                failed.scheduledAt = nil
                failed.sendError = Self.friendly(error)
                saveDraft(failed)
            }
            return false
        }
    }

    /// Outbox: a message that could not go out for lack of connection waits and is tried again
    /// (sooner and sooner apart up to 30 minutes, and right away when the Mac is back online).
    /// After about a day it goes back to Koncepty. Returns true while the message is queued.
    private func queueOutbox(_ draft: ComposeDraft, error: Error) -> Bool {
        let previous = drafts.first { $0.id == draft.id && $0.outbox }
        var queued = draft
        queued.sendAttempts = (previous?.sendAttempts ?? 0) + 1
        queued.sendError = Self.friendly(error)
        let firstTry = previous == nil
        if queued.sendAttempts > 60 {
            queued.outbox = false
            queued.scheduledAt = nil
            saveDraft(queued)
            errorMessage = "Správu „\(draft.subject)“ sa nepodarilo odoslať ani po viacerých pokusoch; je v Konceptoch. \(queued.sendError ?? "")"
            return false
        }
        queued.outbox = true
        let minutes = min(pow(2, Double(queued.sendAttempts - 1)), 30)
        queued.scheduledAt = Date().addingTimeInterval(minutes * 60)
        saveDraft(queued)
        if firstTry {
            showToast("Bez spojenia – správa čaká v Odchádzajúcich a odíde sama")
        }
        return true
    }

    var outboxCount: Int { drafts.filter(\.outbox).count }

    /// Back online: waiting messages are tried right away.
    func retryOutbox() {
        let waiting = drafts.filter(\.outbox)
        guard !waiting.isEmpty else { return }
        for var draft in waiting where (draft.scheduledAt ?? .distantPast) > Date() {
            draft.scheduledAt = Date()
            try? draftStore?.save(draft)
        }
        reloadDrafts()
        Task { await sendDueScheduled() }
    }

    /// Error text for people: what went wrong and what to do, instead of the raw technical message.
    static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "Mac nie je pripojený na internet."
        }
        if lower.contains("offline") || lower.contains("network is down") || lower.contains("not connected") {
            return "Mac nie je pripojený na internet."
        }
        if lower.contains("timed out") || lower.contains("neodpovedal včas") {
            return "Server neodpovedal včas. Skúste to o chvíľu znova."
        }
        if lower.contains("authenticationfailed") || lower.contains("invalid credentials") || lower.contains("535")
            || lower.contains("login failed") || lower.contains("authentication failed") {
            return "Server odmietol prihlásenie – skontrolujte heslo účtu v Nastaveniach → Účty. (\(text))"
        }
        if lower.contains("certificate") || lower.contains("ssl") || lower.contains("tls") {
            return "Zabezpečené spojenie so serverom zlyhalo – skontrolujte server, port a zabezpečenie účtu. (\(text))"
        }
        if lower.contains("host") && (lower.contains("not found") || lower.contains("could not be found") || lower.contains("nodename")) {
            return "Server sa nenašiel – skontrolujte jeho adresu v Nastaveniach → Účty."
        }
        if lower.contains("connection refused") {
            return "Server odmietol spojenie – skontrolujte port a zabezpečenie (SSL/TLS alebo STARTTLS)."
        }
        if lower.contains("552") || lower.contains("message size") || lower.contains("too large") {
            return "Správa je pre server príliš veľká – zmenšite alebo odoberte prílohy. (\(text))"
        }
        return text
    }

    static func fieldValue(_ address: EmailAddress) -> String {
        address.name.map { "\"\($0)\" <\(address.address)>" } ?? address.address
    }

    // MARK: - Drafts

    /// Drafts in the current scope; scheduled ones are listed under "Naplánované" instead.
    var visibleDrafts: [SavedDraft] {
        drafts.filter { $0.scheduledAt == nil && (accountScope == nil || $0.accountID == accountScope) }
    }

    var scheduledDrafts: [SavedDraft] {
        drafts.filter { $0.scheduledAt != nil && (accountScope == nil || $0.accountID == accountScope) }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
    }

    func draftCount(account: String?) -> Int {
        drafts.filter { $0.scheduledAt == nil && (account == nil || $0.accountID == account) }.count
    }

    func scheduledCount(account: String?) -> Int {
        drafts.filter { $0.scheduledAt != nil && (account == nil || $0.accountID == account) }.count
    }

    /// Saves the message to be sent at `date` (Mailmule sends it then, or on its next launch).
    func scheduleSend(_ draft: SavedDraft, at date: Date) {
        var scheduled = draft
        scheduled.scheduledAt = date
        saveDraft(scheduled)
        showToast("Naplánované na \(SnoozeOption.describe(date))")
    }

    /// Sends scheduled messages whose time has come. A failed one goes back to Koncepty.
    private func sendDueScheduled() async {
        // The timer and "back online" can both call this; one run at a time so nothing goes out twice.
        guard !sendingDue else { return }
        sendingDue = true
        defer { sendingDue = false }
        let due = drafts.filter { ($0.scheduledAt ?? .distantFuture) <= Date() }
        for draft in due {
            var message = draft
            message.scheduledAt = nil
            if draft.outbox { message.scheduledAt = draft.scheduledAt }
            let ok = await send(message, delayed: false)
            if ok, let waiting = drafts.first(where: { $0.id == draft.id && $0.outbox }) {
                log("odchádzajúca správa stále čaká (pokus \(waiting.sendAttempts)): \(draft.subject)")
            } else if ok {
                log(draft.outbox ? "odchádzajúca správa odoslaná: \(draft.subject)" : "naplánovaná správa odoslaná: \(draft.subject)")
            } else {
                var failed = drafts.first { $0.id == draft.id } ?? message
                failed.scheduledAt = nil
                failed.outbox = false
                saveDraft(failed)
                log("správa zlyhala, ostáva v konceptoch: \(draft.subject)")
            }
        }
    }

    /// A reply being written to the open thread.
    var draftForSelectedThread: SavedDraft? {
        let ids = Set(messages.compactMap(\.messageID))
        return drafts.first { $0.inReplyTo.map(ids.contains) ?? false }
    }

    func reloadDrafts() {
        drafts = draftStore?.all() ?? []
    }

    /// Stores the draft in the vault; a blank one is removed instead.
    /// Saves the draft in the vault; the server copy follows a little later (`upload` sends it right away).
    func saveDraft(_ draft: SavedDraft, upload: Bool = false) {
        guard let draftStore else { return }
        if draft.isBlank {
            discardDraft(draft.id)
            return
        }
        var draft = draft
        draft.updated = Date()
        // The editor's copy does not know about uploads; keep the server identity.
        if let stored = drafts.first(where: { $0.id == draft.id }) {
            draft.serverMessageID = draft.serverMessageID ?? stored.serverMessageID
            draft.serverSynced = draft.serverSynced ?? stored.serverSynced
        }
        do {
            try draftStore.save(draft)
        } catch {
            log("koncept sa nepodarilo uložiť: \(error)")
        }
        reloadDrafts()
        scheduleDraftUpload(draft.id, immediately: upload)
    }

    func discardDraft(_ id: UUID) {
        let serverID = drafts.first { $0.id == id }.flatMap { draft in draft.serverMessageID.map { (draft.accountID, $0) } }
        draftUploads[id]?.cancel()
        draftStore?.delete(id)
        reloadDrafts()
        if let (accountID, messageID) = serverID, let service = services[accountID] {
            Task {
                do {
                    try await service.deleteServerDraft(messageID: messageID)
                    log("koncept zmazaný aj na serveri: \(messageID)")
                } catch {
                    log("koncept na serveri sa nepodarilo zmazať: \(error)")
                }
            }
        }
    }

    /// Typing saves every second; the server gets the draft 20 s after the last change, or right away on close.
    private func scheduleDraftUpload(_ id: UUID, immediately: Bool) {
        draftUploads[id]?.cancel()
        draftUploads[id] = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .seconds(20)) }
            guard !Task.isCancelled else { return }
            await self?.uploadDraft(id)
        }
    }

    private func uploadDraft(_ id: UUID) async {
        guard let draftStore, let draft = draftStore.all().first(where: { $0.id == id }), draft.scheduledAt == nil,
              let account = account(draft.accountID), let service = services[draft.accountID] else { return }
        let (data, messageID) = draft.mimeMessage(from: account.address)
        do {
            try await service.uploadDraft(data, messageID: messageID)
            // Store the server identity without touching `updated`, unless the draft changed meanwhile.
            guard var current = draftStore.all().first(where: { $0.id == id }) else {
                try? await service.deleteServerDraft(messageID: messageID)
                return
            }
            current.serverMessageID = messageID
            current.serverSynced = current.updated == draft.updated ? Date() : current.serverSynced
            try draftStore.save(current)
            reloadDrafts()
        } catch {
            log("koncept sa nepodarilo nahrať na server: \(error)")
        }
    }

    /// Drafts written on other devices appear here; ones sent or deleted elsewhere go away; local ones go up.
    func syncServerDrafts() async {
        guard let draftStore else { return }
        for (accountID, service) in services {
            let local = draftStore.all().filter { $0.accountID == accountID && $0.scheduledAt == nil }
            let known = Set(local.compactMap(\.serverMessageID))
            do {
                guard let server = try await service.serverDrafts(known: known) else {
                    // No Drafts folder yet: the first upload creates it.
                    for draft in local where draft.serverMessageID == nil { await uploadDraft(draft.id) }
                    continue
                }
                for data in server.new {
                    let draft = SavedDraft(serverDraft: data, accountID: accountID)
                    try draftStore.save(draft)
                    log("koncept zo servera: \(draft.subject)")
                }
                for draft in local {
                    if let messageID = draft.serverMessageID {
                        let unchanged = (draft.serverSynced ?? .distantPast) >= draft.updated
                        if !server.present.contains(messageID) {
                            if unchanged {
                                // Sent or deleted on another device.
                                draftStore.delete(draft.id)
                                log("koncept odstránený inde: \(draft.subject)")
                            } else {
                                await uploadDraft(draft.id)
                            }
                        } else if !unchanged {
                            await uploadDraft(draft.id)
                        }
                    } else {
                        await uploadDraft(draft.id)
                    }
                }
            } catch {
                log("koncepty \(accountID): \(error)")
            }
        }
        reloadDrafts()
    }

    /// Opening a message from the outbox takes it out (so it is not sent while being edited).
    func openDraft(_ draft: SavedDraft) {
        var draft = draft
        if draft.outbox || draft.sendError != nil {
            if draft.outbox { draft.scheduledAt = nil }
            draft.outbox = false
            draft.sendError = nil
            draft.sendAttempts = 0
            saveDraft(draft)
        }
        presentCompose(draft)
    }

    // MARK: - Obsidian & files

    func exportSelectedToObsidian(threadID: String? = nil) {
        guard let id = threadID ?? selectedThreadID,
              let accountID = threads.first(where: { $0.id == id })?.accountID ?? windowThreadAccounts[id],
              let service = services[accountID] else { return }
        guard let vaultURL = settings.obsidianVaultURL else {
            errorMessage = "Najprv nastav Obsidian trezor v Nastaveniach (⌘,)."
            return
        }
        let exporter = ObsidianExporter(vaultURL: vaultURL, folder: settings.obsidianFolder)
        let openAfter = settings.openInObsidianAfterExport
        Task {
            do {
                guard let thread = try await service.exportedThread(id) else { return }
                let url = try exporter.export(thread: thread)
                let count = thread.attachments.count
                showToast(count > 0 ? "Uložené do Obsidianu aj s prílohami (\(count))" : "Uložené do Obsidianu")
                log("obsidian: \(url.path) (\(count) príloh)")
                if openAfter, let open = ObsidianExporter.openURL(for: url) { NSWorkspace.shared.open(open) }
            } catch {
                errorMessage = "Uloženie do Obsidianu zlyhalo: \(error.localizedDescription)"
                log("obsidian chyba: \(error)")
            }
        }
    }

    func openThreadNote() {
        guard let id = selectedThreadID, let thread = selectedThread, let service = services[thread.accountID],
              let vault else { return }
        Task {
            do {
                let files = try await service.writeThreadFiles([id])
                if let filename = files[id] { NSWorkspace.shared.open(vault.threadURL(filename: filename)) }
            } catch {
                errorMessage = error.localizedDescription
            log("chyba: \(error)")
            }
        }
    }

    func revealVault() {
        NSWorkspace.shared.open(settings.mailVaultURL)
    }

    /// Handles `mailmule://thread/<id>` and `mailmule://compose?to=&subject=&body=` links, e.g. from an Obsidian note.
    func handle(url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            composeMailto(url)
            return
        }
        guard url.scheme == "mailmule" else { return }
        // mailmule://person/jan@firma.sk shows the person card.
        if url.host() == "person" {
            let address = url.lastPathComponent
            if address.contains("@") {
                // The name as it appears in the list, if this person wrote recently.
                let name = threads.first { $0.latestSenderAddress.caseInsensitiveCompare(address) == .orderedSame }?.latestSender
                personSheet = PersonSheet(address: EmailAddress(name: name, address: address))
            }
            return
        }
        // mailmule://home shows Prehľad.
        if url.host() == "home" {
            showingDrafts = false
            showingAttachments = false
            showingHome = true
            return
        }
        // mailmule://attachments shows all attachments.
        if url.host() == "attachments" {
            showingDrafts = false
            filter = .inbox
            showingAttachments = true
            return
        }
        // mailmule://settings/privacy opens Settings on that page.
        if url.host() == "settings" {
            if let category = SettingsCategory(rawValue: url.lastPathComponent) { settingsCategory = category }
            settingsOpenRequest += 1
            return
        }
        if url.host() == "compose", let accountID = settings.accounts.first?.id {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
            presentCompose(ComposeDraft(accountID: accountID, to: value("to"), cc: value("cc"),
                                        subject: value("subject"), body: value("body")))
            return
        }
        // mailmule://draft/<id> opens a draft; "?discard=1" throws it away (here and on the server).
        if url.host() == "draft", let id = UUID(uuidString: url.lastPathComponent) {
            guard let draft = drafts.first(where: { $0.id == id }) else { return }
            if Self.testingHooks,
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "discard" }) == true {
                discardDraft(id)
                log("koncept zahodený cez odkaz: \(draft.subject)")
            } else {
                openDraft(draft)
            }
            return
        }
        guard url.host() == "thread" else { return }
        let id = String(url.path(percentEncoded: false).dropFirst())
        guard !id.isEmpty else { return }
        // mailmule://thread/<id>?window=1 opens the thread in a window of its own.
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "window" }) == true {
            openThreadWindow(id)
            return
        }
        Task {
            searchText = ""
            showingDrafts = false
            filter = .all
            await reloadNow()
            selectedThreadID = id
            // mailmule://thread/<id>?summary=1 also writes the summary (e.g. from an Obsidian note).
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // "?preview=1" opens the attachments of the thread in the viewer.
            if query.contains(where: { $0.name == "preview" }) {
                await loadMessages(id)
                _ = previewSelectedAttachments()
            }
            if query.contains(where: { $0.name == "summary" }) {
                await loadMessages(id)
                // "&download=1" skips the download question, only when testing (any web page can open these links).
                summarizeSelectedThread(confirmed: Self.testingHooks && query.contains { $0.name == "download" })
            }
            // "?pdf=<path>" saves the thread as PDF without asking, only when testing.
            if Self.testingHooks, let path = query.first(where: { $0.name == "pdf" })?.value {
                await loadMessages(id)
                if let (html, _) = printableHTML() {
                    await saveThreadPDF(html: html, to: URL(fileURLWithPath: path), reveal: false)
                }
            }
        }
    }

    /// Link actions that change things without asking (discard, model download, PDF to a path) work only when
    /// Mailmule was started with `-MailmuleTestingHooks YES`; a web page can open mailmule:// links.
    static var testingHooks: Bool { UserDefaults.standard.bool(forKey: "MailmuleTestingHooks") }

    /// Appends a line to `<vault>/.mailmule/mailmule.log`.
    func log(_ text: String) {
        Self.logger.notice("\(text, privacy: .public)")
        let url = settings.mailVaultURL.appending(path: ".mailmule/mailmule.log")
        let line = Data("\(Date().formatted(.iso8601)) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url)
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    // MARK: - Keyboard

    /// Single-key shortcuts in the style of Superhuman. Returns true when the key was handled.
    func handleKey(_ characters: String) -> Bool {
        // ⌘Z always undoes; single keys follow Settings → Skratky.
        if characters == "⌘z" { return perform(.undo) }
        guard let action = ShortcutAction.action(for: characters, overrides: settings.shortcuts) else { return false }
        return perform(action)
    }
}


// MARK: - Settings support

extension AppModel {
    /// A disabled account keeps its mail but has no connection, sync or notifications.
    func setAccountEnabled(_ id: String, _ enabled: Bool) {
        settings.disabledAccounts.removeAll { $0 == id }
        if !enabled {
            settings.disabledAccounts.append(id)
            syncErrors[id] = nil
        }
        Task { await configure() }
    }

    func refreshDockBadge() {
        Notifier.setDockBadge(settings.dockBadge ? inboxUnread : 0)
    }

    /// Changes how much mail an account keeps: a stricter limit frees space, a looser one downloads more.
    func updatePolicy(accountID: String, _ policy: SyncPolicy) {
        let previous = settings.syncPolicies[accountID] ?? .init()
        guard policy != previous else { return }
        settings.syncPolicies[accountID] = policy
        guard let service = services[accountID] else { return }
        Task {
            await service.setPolicy(policy)
            applyPolicy(accountID: accountID)
            await syncAccount(accountID)
        }
    }

    func messageCounts() async -> [String: Int] {
        (try? await index?.messageCounts()) ?? [:]
    }

    func checkDatabase() async -> String {
        guard let index else { return "index nie je otvorený" }
        do {
            let result = try await index.integrityCheck()
            log("kontrola databázy: \(result)")
            return result
        } catch {
            return error.localizedDescription
        }
    }

    var logURL: URL {
        settings.mailVaultURL.appending(path: ".mailmule/mailmule.log")
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    /// Log tail, versions and account state; no passwords and no mail content.
    func exportDiagnostics(to url: URL) async {
        let info = Bundle.main.infoDictionary
        var lines = [
            "Mailmule \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Vytvorené \(Date().formatted(.iso8601))",
            "",
            "Účty:",
        ]
        let counts = await messageCounts()
        for account in settings.accounts {
            let state = settings.disabledAccounts.contains(account.id) ? "vypnutý"
                : syncErrors[account.id].map { "chyba: \($0)" }
                ?? accountLastSync[account.id].map { "synchronizované \($0.formatted(.iso8601))" } ?? "nesynchronizované"
            let policy = settings.syncPolicies[account.id] ?? .init()
            lines.append("- \(account.email) · \(account.imapHost):\(account.imapPort) / \(account.smtpHost):\(account.smtpPort) · \(counts[account.id] ?? 0) správ · história \(policy.historyMonths.map { "\($0) mes." } ?? "všetko"), prílohy \(policy.attachments) · \(state)")
        }
        lines.append("")
        lines.append("Databáza: \(await checkDatabase())")
        lines.append("")
        lines.append("Záznam (posledných 400 riadkov):")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        lines += log.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).map(String.init)
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            showToast("Diagnostika uložená")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The UserDefaults keys that make up the settings (app settings, list view, theme).
    private static func settingsKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0 == "settings" || $0 == "listView" || $0.hasPrefix("theme.")
        }
    }

    func exportSettings(to url: URL, quiet: Bool = false) {
        var payload: [String: Any] = ["format": "mailmule-settings-1"]
        for key in Self.settingsKeys() {
            guard let value = UserDefaults.standard.object(forKey: key) else { continue }
            // Codable settings are stored as JSON data; keep them readable in the file.
            if let data = value as? Data, let json = try? JSONSerialization.jsonObject(with: data) {
                payload[key] = ["json": json]
            } else {
                payload[key] = value
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            if !quiet { showToast("Nastavenia exportované") }
        } catch {
            if quiet { return log("záloha nastavení zlyhala: \(error)") }
            errorMessage = "Nastavenia sa nepodarilo exportovať: \(error.localizedDescription)"
        }
    }

    func importSettings(from url: URL) async {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["format"] as? String == "mailmule-settings-1" else {
            errorMessage = "Súbor nie je export nastavení Mailmule."
            return
        }
        for (key, value) in payload where key == "settings" || key == "listView" || key.hasPrefix("theme.") {
            if let wrapped = value as? [String: Any], let json = wrapped["json"],
               let encoded = try? JSONSerialization.data(withJSONObject: json) {
                UserDefaults.standard.set(encoded, forKey: key)
            } else {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        settings = AppSettings.load()
        listView = ListViewSettings.load()
        ThemeStore.shared.reload()
        log("nastavenia importované z \(url.lastPathComponent)")
        showToast("Nastavenia importované")
        await configure()
    }

    /// Everything back to defaults except accounts, signatures and tag colors.
    func resetSettingsToDefaults() {
        var fresh = AppSettings()
        fresh.accounts = settings.accounts
        fresh.syncPolicies = settings.syncPolicies
        fresh.signatures = settings.signatures
        fresh.tagColors = settings.tagColors
        fresh.mailVaultPath = settings.mailVaultPath
        fresh.obsidianVaultPath = settings.obsidianVaultPath
        fresh.obsidianFolder = settings.obsidianFolder
        settings = fresh
        listView = ListViewSettings()
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("theme.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        ThemeStore.shared.reload()
        refreshDockBadge()
        Task { await configure() }
        showToast("Nastavenia obnovené")
    }

    /// Window size and column widths come back at the next launch.
    func resetWindowLayout() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView") || key.hasPrefix("NSNavigationSplit") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        showToast("Rozloženie okien sa obnoví pri ďalšom spustení")
    }

    /// Removes all passwords from the Keychain and stops syncing; accounts and mail stay.
    func signOutAllAccounts() async {
        for account in settings.accounts { Keychain.deletePassword(for: account.id) }
        log("všetky účty odhlásené")
        await configure()
    }

    /// Zips the whole mail vault with `ditto` (keeps Finder tags and extended attributes).
    func backupVault(to url: URL) async {
        let source = settings.mailVaultURL
        let result: (status: Int32, error: String) = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, url.path]
            let pipe = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return (process.terminationStatus, message)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
        if result.status == 0 {
            log("záloha: \(url.path)")
            showToast("Záloha uložená")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errorMessage = "Zálohu sa nepodarilo vytvoriť: \(result.error)"
        }
    }

    /// A warning when the sender looks forged: a different address inside the display name,
    /// or replies going to another domain.
    func senderWarning(for message: StoredMessage) -> String? {
        guard settings.warnSuspicious, let from = message.from, !isOwn(from) else { return nil }
        let address = from.address.lowercased()
        if let name = from.name,
           let range = name.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
            let embedded = name[range].lowercased()
            if embedded != address {
                return "Meno odosielateľa obsahuje adresu \(embedded), ale správa prišla z \(address)."
            }
        }
        // Invoicing and newsletter services legitimately reply to their client's domain; the scam pattern is a
        // company sender whose replies go to a free mailbox ("the boss" writing from a Gmail address).
        if let replyTo = mime(for: message)?.replyTo.first?.address.lowercased(),
           Self.baseDomain(of: replyTo) != Self.baseDomain(of: address),
           Self.freeMailDomains.contains(Self.baseDomain(of: replyTo)),
           !Self.freeMailDomains.contains(Self.baseDomain(of: address)) {
            return "Odpoveď pôjde na súkromnú schránku \(replyTo), nie na odosielateľa \(address)."
        }
        return nil
    }

    static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "icloud.com",
        "me.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "gmx.net", "mail.com", "zoho.com",
        "azet.sk", "centrum.sk", "zoznam.sk", "post.sk", "pobox.sk", "seznam.cz", "centrum.cz", "email.cz", "atlas.cz",
    ]

    /// `mail.firma.sk` → `firma.sk` (good enough to compare sender and Reply-To).
    static func baseDomain(of address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? address
        return domain.split(separator: ".").suffix(2).joined(separator: ".")
    }
}


// MARK: - Rules

extension AppModel {
    /// Runs the arrival rules on new inbox mail; returns threads that should arrive quietly.
    func applyRules(toIncoming messages: [StoredMessage]) async -> Set<String> {
        let rules = settings.rules.filter { $0.enabled && $0.afterDays == nil }
        guard !rules.isEmpty else { return [] }
        var quiet: Set<String> = []
        var done: Set<String> = []
        for message in messages where !done.contains(message.threadID) {
            let context = RuleContext(message: message, mime: mime(for: message))
            // Only mail that arrived after the rule was made; older mail is handled by "Spustiť teraz".
            let actions = rules.filter { message.date >= $0.createdAt && RuleEngine.matches($0, context) }.flatMap(\.actions)
            guard !actions.isEmpty else { continue }
            done.insert(message.threadID)
            if actions.contains(.noNotification) || actions.contains(.archive) || actions.contains(.trash)
                || actions.contains(where: { if case .moveToFolder = $0 { true } else { false } }) {
                quiet.insert(message.threadID)
            }
            await perform(actions, threadID: message.threadID, accountID: message.accountID)
            log("pravidlá: \(message.subject.prefix(60)) → \(actions.map(describe).joined(separator: ", "))")
        }
        if !done.isEmpty { await reloadNow() }
        return quiet
    }

    /// Rules with "po N dňoch": inbox threads whose latest message is older than that.
    func sweepDelayedRules() async {
        let rules = settings.rules.filter { $0.enabled && $0.afterDays != nil }
        guard !rules.isEmpty else { return }
        var changed = 0
        for rule in rules {
            changed += await run(rule, olderThanDays: rule.afterDays ?? 0)
        }
        if changed > 0 {
            log("pravidlá po dňoch: \(changed) vlákien")
            await reloadNow()
        }
    }

    /// "Spustiť teraz": the rule over the whole Doručená pošta (respecting its "po N dňoch").
    func runRuleNow(_ rule: MailRule) async {
        let count = await run(rule, olderThanDays: rule.afterDays ?? 0)
        await reloadNow()
        showToast(count == 0 ? "Pravidlu „\(rule.name)“ nezodpovedá nič v Doručenej pošte"
                             : "Pravidlo „\(rule.name)“: \(count) vlákien")
    }

    private func run(_ rule: MailRule, olderThanDays days: Int) async -> Int {
        guard let index else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let threads = (try? await index.threads(filter: .inbox, accountID: rule.accountID, limit: 5000)) ?? []
        var count = 0
        for thread in threads where thread.date <= cutoff {
            guard let messages = try? await index.messages(inThread: thread.id),
                  let latest = messages.last(where: { !isOwn($0.from) }) ?? messages.last else { continue }
            guard RuleEngine.matches(rule, RuleContext(message: latest, mime: mime(for: latest))) else { continue }
            await perform(rule.actions, threadID: thread.id, accountID: thread.accountID)
            count += 1
        }
        return count
    }

    private func perform(_ actions: [RuleAction], threadID: String, accountID: String) async {
        guard let service = services[accountID] else { return }
        // Mark and tag first; moving the thread away comes last.
        let ordered = actions.sorted { Self.order($0) < Self.order($1) }
        for action in Set(ordered).sorted(by: { Self.order($0) < Self.order($1) }) {
            do {
                switch action {
                case .markRead: try await service.setSeen(threadID, true)
                case .star: try await service.setStarred(threadID, true)
                case .tag(let tag): try await service.setTag(canonicalTag(tag), true, threadID: threadID)
                case .noNotification: break
                case .archive:
                    if settings.markReadOnArchive { try await service.setSeen(threadID, true) }
                    try await service.archiveThread(threadID)
                case .moveToFolder(let mailbox): try await service.moveThread(threadID, toMailbox: mailbox)
                case .trash: try await service.deleteThread(threadID)
                }
            } catch {
                log("pravidlo \(describe(action)) zlyhalo: \(error)")
            }
        }
    }

    /// Folders a rule can move mail to: those of its account (or of the only account).
    func ruleFolders(accountID: String?) -> [FolderInfo] {
        let id = accountID ?? (settings.accounts.count == 1 ? settings.accounts.first?.id : nil)
        return id.flatMap { foldersByAccount[$0] } ?? []
    }

    /// Display name of a server folder ("INBOX.Klienti" → "Klienti").
    func folderTitle(_ mailbox: String) -> String {
        foldersByAccount.values.joined().first { $0.name == mailbox }?.path.joined(separator: " / ") ?? mailbox
    }

    private static func order(_ action: RuleAction) -> Int {
        switch action {
        case .noNotification: 0
        case .markRead: 1
        case .star: 2
        case .tag: 3
        case .moveToFolder: 4
        case .archive: 5
        case .trash: 6
        }
    }

    func describe(_ action: RuleAction) -> String {
        switch action {
        case .archive: "archivovať"
        case .markRead: "označiť ako prečítané"
        case .star: "označiť hviezdičkou"
        case .trash: "presunúť do koša"
        case .noNotification: "bez upozornenia"
        case .tag(let tag): "štítok „\(tag)“"
        case .moveToFolder(let mailbox): "presunúť do „\(folderTitle(mailbox))“"
        }
    }
}


// MARK: - Follow-ups

extension AppModel {
    /// "Pripomenúť, ak neodpovie" for threads you are waiting on.
    func setFollowUp(_ threadIDs: [String]? = nil, due: Date) {
        let ids = threadIDs ?? targetThreadIDs
        guard let index, !ids.isEmpty else { return }
        Task {
            for id in ids {
                guard let accountID = threads.first(where: { $0.id == id })?.accountID ?? selectedThread.map(\.accountID) else { continue }
                try? await index.setFollowUp(threadID: id, account: accountID, due: due, since: Date())
            }
            await reloadNow()
            showToast("Pripomenie sa \(SnoozeOption.describe(due)), ak neodpovie")
        }
    }

    func clearFollowUp(_ threadIDs: [String]? = nil) {
        let ids = threadIDs ?? targetThreadIDs
        guard let index, !ids.isEmpty else { return }
        Task {
            for id in ids { try? await index.removeFollowUp(threadID: id) }
            await reloadNow()
        }
    }

    /// Answered reminders disappear; unanswered ones bring the thread back to the inbox when due.
    func checkFollowUps() async {
        guard let index, let all = try? await index.followUps(), !all.isEmpty else { return }
        let own = settings.accounts.map(\.email)
        var changed = false
        for followUp in all.values {
            if (try? await index.hasReply(threadID: followUp.threadID, after: followUp.since, ownAddresses: own)) == true {
                try? await index.removeFollowUp(threadID: followUp.threadID)
                log("pripomienka zrušená, prišla odpoveď: \(followUp.threadID)")
                changed = true
            } else if !followUp.fired, followUp.due <= Date(), let service = services[followUp.accountID] {
                do {
                    try await service.moveThreadToInbox(followUp.threadID)
                    try await index.markFollowUpFired(threadID: followUp.threadID)
                    if let message = try await index.messages(inThread: followUp.threadID).last {
                        Notifier.notifyFollowUp(subject: message.subject, threadID: followUp.threadID, settings: settings)
                    }
                    log("bez odpovede, vlákno vrátené do Doručenej: \(followUp.threadID)")
                    changed = true
                } catch {
                    log("pripomienka chyba: \(error)")
                }
            }
        }
        if changed { await reloadNow() }
    }
}

/// When a "pripomenúť, ak neodpovie" reminder comes due.
enum FollowUpOption: CaseIterable {
    case tomorrow, threeDays, week, twoWeeks

    var title: String {
        switch self {
        case .tomorrow: "Zajtra"
        case .threeDays: "O 3 dni"
        case .week: "O týždeň"
        case .twoWeeks: "O 2 týždne"
        }
    }

    /// At 9:00 on the day, so the reminder is there in the morning.
    var date: Date {
        let calendar = Calendar.current
        let days = switch self {
        case .tomorrow: 1
        case .threeDays: 3
        case .week: 7
        case .twoWeeks: 14
        }
        let day = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}


// MARK: - Unsubscribe

extension AppModel {
    func unsubscribeInfo(for message: StoredMessage) -> UnsubscribeInfo? {
        guard !isOwn(message.from) else { return nil }
        return mime(for: message)?.unsubscribe
    }

    func isUnsubscribed(_ message: StoredMessage) -> Date? {
        message.from.flatMap { settings.unsubscribed[$0.address.lowercased()] }
    }

    /// Leaves the newsletter the best way it offers (one-click POST, e-mail, or its web page) and archives the thread.
    func unsubscribe(from message: StoredMessage) async {
        guard let info = unsubscribeInfo(for: message), let method = info.preferred,
              let sender = message.from?.address.lowercased() else { return }
        let name = message.from?.displayName ?? sender
        switch method {
        case .oneClick(let url):
            do {
                let session = URLSession(configuration: .ephemeral)
                let (_, response) = try await session.data(for: UnsubscribeInfo.oneClickRequest(url))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<400).contains(status) else {
                    log("odhlásenie \(sender): HTTP \(status), otváram stránku")
                    NSWorkspace.shared.open(url)
                    showToast("Odhlásenie dokončite na stránke odosielateľa")
                    return
                }
                log("odhlásené (one-click): \(sender)")
                showToast("Odhlásené z odberu: \(name)")
            } catch {
                errorMessage = "Odhlásenie sa nepodarilo: \(error.localizedDescription)"
                return
            }
        case .email(let address, let subject, let body):
            guard let service = services[message.accountID], let account = account(message.accountID) else { return }
            do {
                let draft = Draft(from: account.address, to: [EmailAddress(name: nil, address: address)],
                                  subject: subject, markdown: body.isEmpty ? "unsubscribe" : body)
                _ = try await service.send(draft)
                log("odhlásené (e-mail na \(address)): \(sender)")
                showToast("Odhlasovací e-mail odoslaný: \(name)")
            } catch {
                errorMessage = "Odhlasovací e-mail sa nepodarilo odoslať: \(error.localizedDescription)"
                return
            }
        case .website(let url):
            NSWorkspace.shared.open(url)
            log("odhlásenie cez web: \(sender)")
            showToast("Odhlásenie dokončite na stránke odosielateľa")
        }
        settings.unsubscribed[sender] = Date()
        move([message.threadID], to: .archive)
    }
}


// MARK: - Assistant

/// What waits for the user's OK to download the model.
enum AssistantRequest: Identifiable {
    case summary(String)
    case reply(String)

    var id: String {
        switch self {
        case .summary(let id): "summary-" + id
        case .reply(let id): "reply-" + id
        }
    }
}

extension AppModel {
    var assistantNeedsDownload: Bool { !localModel.isDownloaded(settings.assistantModel) }

    /// The user agreed to download the model: continue with what they asked for.
    func confirmAssistantDownload(_ request: AssistantRequest) {
        assistantDownloadRequest = nil
        switch request {
        case .summary: summarizeSelectedThread(confirmed: true)
        case .reply: replySuggestionRequest += 1
        }
    }

    /// The thread as plain text for the model: newest messages first get the space, quotes are dropped.
    func assistantTranscript(_ messages: [StoredMessage], limit: Int = 9000) -> String {
        var parts: [String] = []
        var used = 0
        for message in messages.reversed() {
            let sender = isOwn(message.from) ? "Ja (\(message.from?.address ?? ""))" : (message.from.map { "\($0.displayName) <\($0.address)>" } ?? "?")
            let body = Self.ownText(mime(for: message)?.bestText ?? message.bodyText)
            let piece = "Od: \(sender)\nDátum: \(message.date.formatted(date: .abbreviated, time: .shortened))\n\n\(body.prefix(2500))"
            if used + piece.count > limit && !parts.isEmpty { break }
            parts.insert(piece, at: 0)
            used += piece.count
        }
        let subject = messages.last?.subject ?? ""
        return "Predmet: \(subject)\n\n" + parts.joined(separator: "\n\n-----\n\n")
    }

    /// The new text of a message: without quoted lines and the quoted original under "Dňa … napísal(a):".
    static func ownText(_ text: String) -> String {
        var lines: [String] = []
        let all = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (offset, line) in all.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            // Outlook quotes the original under a "From: / Sent: / To:" block instead of ">" lines.
            if trimmed.range(of: #"^\**(From|Od):\**\s"#, options: .regularExpression) != nil,
               all.dropFirst(offset + 1).prefix(3).contains(where: {
                   $0.trimmingCharacters(in: .whitespaces).range(of: #"^\**(Sent|Date|Odoslané|Dátum|Komu|To):"#, options: .regularExpression) != nil
               }) { break }
            if trimmed.range(of: #"^(Dňa|On|Am|Dne|Le) .{4,120}(napísal|napsal|wrote|schrieb|écrit).{0,6}:$"#, options: .regularExpression) != nil { break }
            if trimmed.hasPrefix("-----Original Message") || trimmed.hasPrefix("-----Pôvodná správa") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Zhrnúť": a short summary of the selected thread, written into `summaries` as it streams.
    /// ✨: shows the stored summary when it is current, otherwise writes a new one.
    func showSummary() {
        guard let id = selectedThreadID else { return }
        Task {
            if let stored = try? await index?.summary(threadID: id), stored.latestKey == messages.last?.key {
                summaries[id] = stored.text
                summaryOutdated[id] = false
            } else {
                summarizeSelectedThread()
            }
        }
    }

    func summarizeSelectedThread(confirmed: Bool = false) {
        guard settings.assistantEnabled, let id = selectedThreadID, !messages.isEmpty else { return }
        if assistantNeedsDownload && !confirmed {
            assistantDownloadRequest = .summary(id)
            return
        }
        let transcript = assistantTranscript(messages)
        let latestKey = messages.last?.key ?? ""
        summarizing = id
        summaries[id] = ""
        summaryOutdated[id] = false
        Task {
            do {
                _ = try await localModel.generate(settings.assistantModel, instructions: Self.summaryInstructions,
                                                  prompt: transcript, maxTokens: 500) { [weak self] text in
                    self?.summaries[id] = text
                }
                if let text = summaries[id], !text.isEmpty {
                    try? await index?.setSummary(text, threadID: id, latestKey: latestKey)
                }
                log("súhrn vlákna \(id)")
            } catch {
                summaries[id] = nil
                errorMessage = "Súhrn sa nepodarilo vytvoriť: \(error.localizedDescription)"
                log("asistent chyba: \(error)")
            }
            if summarizing == id { summarizing = nil }
        }
    }

    /// "Navrhnúť odpoveď": a draft reply to the newest message, streamed into `onText`.
    func suggestReply(confirmed: Bool = false, onText: @escaping @MainActor (String) -> Void) async -> Bool {
        guard settings.assistantEnabled, let id = selectedThreadID, !messages.isEmpty else { return false }
        if assistantNeedsDownload && !confirmed {
            assistantDownloadRequest = .reply(id)
            return false
        }
        let account = messages.last.flatMap { self.account($0.accountID) }
        let instructions = Self.replyInstructions(name: account?.name ?? "používateľ")
        do {
            _ = try await localModel.generate(settings.assistantModel, instructions: instructions,
                                              prompt: assistantTranscript(messages, limit: 6000), maxTokens: 350, onText: onText)
            return true
        } catch {
            errorMessage = "Návrh odpovede sa nepodarilo vytvoriť: \(error.localizedDescription)"
            log("asistent chyba: \(error)")
            return false
        }
    }

    static let summaryInstructions = """
    Si asistent v e-mailovom programe. Odpovedaj výhradne po slovensky, stručne a vecne.
    Zhrň e-mailové vlákno do 3 až 6 krátkych odrážok začínajúcich znakom „- “: o čom je, kto čo chce,
    čo sa dohodlo, dôležité termíny, sumy a čísla. Sumy, čísla, percentá a podmienky uvádzaj presne tak,
    ako sú v texte, a nespájaj rôzne čísla dokopy. Nič nepridávaj ani nedomýšľaj – ak niečo vo vlákne nie je,
    nepíš to. Ak má používateľ („Ja“) niečo urobiť, pridaj na koniec riadok „Úloha: …“. Nepíš úvod ani záver.
    """

    static func replyInstructions(name: String) -> String {
        """
        Si asistent v e-mailovom programe a píšeš v mene používateľa (\(name), vo vlákne „Ja“).
        Napíš návrh odpovede na poslednú prijatú správu vo vlákne. Píš po slovensky, ak posledná správa nie je
        v inom jazyku – potom jej jazykom. Zdvorilo a stručne, 2 až 5 viet, s oslovením na začiatku.
        Bez predmetu, bez podpisu, bez vysvetľovania, len samotný text odpovede.
        Ak treba údaj, ktorý vo vlákne nie je (termín, cena), napíš na jeho miesto [doplniť].
        """
    }
}


// MARK: - Windows

enum WindowRequest: Equatable {
    case thread(String)
    case compose(UUID)
    case viewer(String)
}

extension AppModel {
    /// The messages of a thread for a window of its own (marks it read like opening it in the list).
    func threadWindowMessages(_ threadID: String) async -> [StoredMessage] {
        let loaded = (try? await index?.messages(inThread: threadID)) ?? []
        if let accountID = loaded.last?.accountID {
            windowThreadAccounts[threadID] = accountID
            if loaded.contains(where: { !$0.seen }), let service = services[accountID] {
                try? await service.markThreadSeen(threadID)
                await reloadNow()
            }
        }
        return loaded
    }

    func openThreadWindow(_ threadID: String) {
        windowRequest = .thread(threadID)
    }
}


// MARK: - Default mail app, Services

extension AppModel {
    /// A mailto: link (RFC 6068) from Safari, a PDF or any app: a new message, nothing is sent.
    func composeMailto(_ url: URL) {
        guard let accountID = defaultSenderID else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var fields: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            fields[item.name.lowercased()] = item.value ?? ""
        }
        let path = components?.path.removingPercentEncoding ?? ""
        let to = [path, fields["to"] ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        let body = fields["body"].map { $0.replacingOccurrences(of: "\r\n", with: "\n") } ?? ""
        NSApp.activate()
        presentCompose(ComposeDraft(accountID: accountID, to: to, cc: fields["cc"] ?? "", subject: fields["subject"] ?? "",
                                    body: body + signatureBlock(accountID, kind: .new)))
    }

    /// "Poslať e-mailom v Mailmule" from Finder: a new message with the files attached.
    func composeWithFiles(_ urls: [URL]) {
        guard let accountID = defaultSenderID else { return }
        let files = urls.filter { !$0.hasDirectoryPath }
        let attachments = files.compactMap { url in
            (try? Data(contentsOf: url)).map { OutgoingAttachment(filename: url.lastPathComponent, data: $0) }
        }
        guard !attachments.isEmpty else { return }
        let subject = attachments.count == 1 ? attachments[0].filename : "\(attachments.count) súbory"
        NSApp.activate()
        presentCompose(ComposeDraft(accountID: accountID, subject: subject,
                                    body: signatureBlock(accountID, kind: .new), attachments: attachments))
    }

    /// "Nový e-mail s označeným textom" from any app.
    func composeWithText(_ text: String) {
        guard let accountID = defaultSenderID else { return }
        NSApp.activate()
        presentCompose(ComposeDraft(accountID: accountID, body: text + signatureBlock(accountID, kind: .new)))
    }

    var isDefaultMailApp: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:test@example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm the change.
    func makeDefaultMailApp() async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
            showToast("Mailmule je predvolená e-mailová aplikácia")
        } catch {
            errorMessage = "Nepodarilo sa nastaviť Mailmule ako predvolenú poštu: \(error.localizedDescription)"
        }
    }
}


// MARK: - Attachments view

/// One attachment in the Prílohy view.
struct AttachmentItem: Identifiable, Hashable {
    var id: String { message.key + "/" + filename }
    let message: StoredMessage
    let filename: String

    enum Kind: String, CaseIterable {
        case all = "Všetky", pdf = "PDF", image = "Obrázky", document = "Dokumenty", sheet = "Tabuľky", other = "Ostatné"
    }

    var kind: Kind { Self.kind(of: filename) }

    static func kind(of filename: String) -> Kind {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": .pdf
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg": .image
        case "doc", "docx", "odt", "rtf", "txt", "pages", "md", "ppt", "pptx", "key", "odp": .document
        case "xls", "xlsx", "csv", "ods", "numbers": .sheet
        default: .other
        }
    }
}

extension AppModel {
    func attachmentItems() async -> [AttachmentItem] {
        let messages = (try? await index?.attachmentMessages(accountID: accountScope)) ?? []
        return messages.flatMap { message in
            message.attachments.filter { !Self.isSignatureImage($0) }.map { AttachmentItem(message: message, filename: $0) }
        }
    }

    /// Logos and icons pasted into signatures (Outlook's image001.png, Outlook-xyz.png), not real attachments.
    static func isSignatureImage(_ name: String) -> Bool {
        name.range(of: #"^(image\d{3}|Outlook-[\w-]+|~WRD\d+)\.(png|jpe?g|gif|bmp)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A file on disk for dragging to Finder; nil while the attachment is still on the server.
    func attachmentFile(_ item: AttachmentItem) -> URL? {
        guard let part = mime(for: item.message)?.root.leaves.first(where: {
            $0.isAttachment && ($0.filename ?? "príloha") == item.filename && $0.stubSize == nil
        }) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Mailmule/\(item.message.key)")
        let url = dir.appending(path: item.filename.replacingOccurrences(of: "/", with: "-"))
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? part.decodedBody.write(to: url)
        }
        return url
    }

    /// Shows the attachment's message in the thread pane.
    func showMessage(of item: AttachmentItem) {
        selectedThreadID = item.message.threadID
    }
}


struct PersonSheet: Identifiable {
    var id: String { address.address }
    let address: EmailAddress
}


// MARK: - Prehľad (home)

/// What the Prehľad page shows, loaded together.
struct HomeData {
    var unread: [ThreadSummary] = []
    var vipOnly = false
    var events: [HomeEvent] = []
    var waiting: [(thread: ThreadSummary, followUp: FollowUp)] = []
    var returning: [(thread: ThreadSummary, date: Date)] = []
    var scheduled: [SavedDraft] = []
    var attachments: [AttachmentItem] = []
    var inbox: [(account: Account, unread: Int)] = []
}

extension AppModel {
    func homeData() async -> HomeData {
        guard let index else { return HomeData() }
        var data = HomeData()
        let unread = (try? await index.threads(filter: .inbox, options: ThreadListOptions(unreadOnly: true), limit: 200)) ?? []
        let vips = unread.filter { AppSettings.matches($0.latestSenderAddress, settings.vipSenders) }
        data.vipOnly = !settings.vipSenders.isEmpty
        data.unread = data.vipOnly ? vips : unread
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        let invites = ((try? await index.events(from: today, to: dayAfterTomorrow)) ?? []).filter { !$0.isCancelled }
        data.events = CalendarLink.merge(invites: invites,
                                         calendar: settings.calendarConnected
                                             ? CalendarLink.events(from: today, to: dayAfterTomorrow, hidden: settings.calendarHidden) : [])
        let followed = (try? await index.threads(filter: .followUps, limit: 100)) ?? []
        data.waiting = followed.compactMap { thread in followUps[thread.id].map { (thread, $0) } }
            .sorted { ($0.followUp.fired ? 0 : 1, $0.followUp.due) < ($1.followUp.fired ? 0 : 1, $1.followUp.due) }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let snoozed = (try? await index.threads(filter: .snoozed, limit: 100)) ?? []
        data.returning = snoozed.compactMap { thread in snoozes[thread.id].map { (thread, $0) } }
            .filter { $0.date < endOfToday }.sorted { $0.date < $1.date }
        data.scheduled = drafts.filter { $0.scheduledAt != nil }.sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
        data.attachments = Array(await attachmentItems().prefix(8))
        data.inbox = settings.accounts.map { ($0, unreadByAccount[$0.id] ?? 0) }
        return data
    }

    /// The saved search being shown, when the search field holds one.
    var activeSavedSearch: SavedSearch? {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : settings.savedSearches.first { $0.query == query }
    }

    func saveSearch(name: String) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let title = name.trimmingCharacters(in: .whitespaces)
        settings.savedSearches.append(SavedSearch(name: title.isEmpty ? query : title, query: query))
        showToast("Hľadanie uložené do bočného panela")
    }

    func moveSavedSearch(_ search: SavedSearch, by offset: Int) {
        guard let index = settings.savedSearches.firstIndex(where: { $0.id == search.id }),
              settings.savedSearches.indices.contains(index + offset) else { return }
        settings.savedSearches.swapAt(index, index + offset)
    }

    /// Opens a thread from Prehľad in the mail columns.
    func openFromHome(_ threadID: String) {
        showingHome = false
        showingAttachments = false
        selectedThreadID = threadID
    }

    /// Invitations stored before events were indexed: looked through once, in the background.
    func backfillEventsIfNeeded() {
        guard !settings.eventsBackfilled, !services.isEmpty else { return }
        let all = Array(services.values)
        Task {
            var found = 0
            for service in all { found += (try? await service.indexStoredEvents()) ?? 0 }
            settings.eventsBackfilled = true
            log("pozvánky v uloženej pošte: \(found)")
        }
    }
}
