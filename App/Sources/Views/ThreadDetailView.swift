import AppKit
import MailmuleKit
import SwiftUI
import UniformTypeIdentifiers

struct ThreadDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.selection.count > 1 {
                BulkSelectionView()
            } else if model.messages.isEmpty {
                ContentUnavailableView("Vyber vlákno", systemImage: "envelope",
                                       description: Text(model.shortcutOverview))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ThreadTitle()
                        if let id = model.selectedThreadID, model.summaries[id] != nil {
                            SummaryCard(threadID: id)
                        }
                        if let draft = model.draftForSelectedThread {
                            HStack {
                                Image(systemName: "pencil.line")
                                Text("Máš rozpísanú odpoveď")
                                Spacer()
                                Button("Pokračovať\(model.shortcutHint(.reply))") { model.openDraft(draft) }
                            }
                            .padding(10)
                            .background(Color.themeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(model.messages) { message in
                            MessageCard(message: message,
                                        initiallyExpanded: message.id == model.messages.last?.id || !message.seen)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 920, alignment: .leading)
                }
                .id(model.selectedThreadID)
                .safeAreaInset(edge: .top, spacing: 0) { ThreadActionBar() }
                .safeAreaInset(edge: .bottom, spacing: 0) { QuickReplyBar() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
    }
}

/// Actions above the open thread (as in the design): archive, delete, move, tag, more; reply on the right.
private struct ThreadActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if model.filter == .archive {
                icon("tray.and.arrow.down", "Presunúť do Doručenej pošty\(model.shortcutHint(.toInbox))") { model.moveSelectedToInbox() }
            } else {
                icon("archivebox", "Archivovať\(model.shortcutHint(.archive))") { model.archiveSelected() }
            }
            icon("trash", model.filter == .trash ? "Zmazať natrvalo\(model.shortcutHint(.delete))" : "Presunúť do koša\(model.shortcutHint(.delete))") { model.deleteSelected() }
            icon("folder", "Presunúť do priečinka\(model.shortcutHint(.move))") { model.openFolderPicker() }
            icon("tag", "Štítky\(model.shortcutHint(.tag))") { model.openTagPicker() }
            icon("clock", model.filter == .snoozed ? "Zmeniť čas odloženia\(model.shortcutHint(.snooze))" : "Odložiť\(model.shortcutHint(.snooze))") { model.openSnoozePicker() }
            if model.settings.assistantEnabled {
                icon("sparkles", "Zhrnúť vlákno (lokálny model)") { model.showSummary() }
                    .disabled(model.summarizing != nil)
            }
            Menu {
                Button(model.selectedThread?.flagged == true ? "Odstrániť hviezdičku" : "Označiť hviezdičkou") { model.toggleStar() }
                Button(model.selectedThread?.isUnread == true ? "Označiť ako prečítané" : "Označiť ako neprečítané") { model.toggleRead() }
                Divider()
                Button("Predchádzajúce vlákno\(model.shortcutHint(.previous))") { model.moveSelection(-1) }
                Button("Ďalšie vlákno\(model.shortcutHint(.next))") { model.moveSelection(1) }
                Divider()
                Button("Uložiť do Obsidianu") { model.exportSelectedToObsidian() }
                Button("Tlačiť… (⌘P)") { model.printSelectedThread() }
                Button("Exportovať ako PDF…") { model.exportSelectedThreadAsPDF() }
                Button("Otvoriť poznámku vlákna (.md)") { model.openThreadNote() }
                if model.filter != .inbox {
                    Button("Presunúť do Doručenej pošty") { model.moveSelectedToInbox() }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 28)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Ďalšie akcie")
            Spacer()
            icon("arrowshape.turn.up.left", "Odpovedať\(model.shortcutHint(.reply))") { model.reply(all: false) }
            icon("arrowshape.turn.up.right", "Preposlať\(model.shortcutHint(.forward))") { model.forward() }
            HStack(spacing: 0) {
                Button { model.reply(all: false) } label: {
                    Label("Odpovedať", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .frame(height: 30)
                }
                Divider().frame(height: 18)
                Menu {
                    Button("Odpovedať všetkým\(model.shortcutHint(.replyAll))") { model.reply(all: true) }
                    Button("Preposlať\(model.shortcutHint(.forward))") { model.forward() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 30)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.leading, 6)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .themedChrome()
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown instead of a thread when several are selected: actions for all of them.
private struct BulkSelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.targetThreadIDs
        let selected = model.threads.filter { ids.contains($0.id) }
        VStack(spacing: 18) {
            Image(systemName: "envelope.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(ids.count) vybraných vlákien")
                .font(.title2.weight(.semibold))
            let accounts = Set(selected.map(\.accountID)).count
            if accounts > 1 {
                Text("z \(accounts) účtov").foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    action("Archivovať", "archivebox", "e") { model.archiveSelected() }
                    action(model.filter == .trash ? "Zmazať natrvalo" : "Do koša", "trash", "#") { model.deleteSelected() }
                    action("Presunúť…", "folder", "v") { model.openFolderPicker() }
                }
                GridRow {
                    action(selected.contains(where: \.isUnread) ? "Prečítané" : "Neprečítané",
                           selected.contains(where: \.isUnread) ? "envelope.open" : "envelope.badge", "u") { model.toggleRead() }
                    action(selected.allSatisfy(\.flagged) ? "Bez hviezdičky" : "Hviezdička", "star", "s") { model.toggleStar() }
                    action("Štítok…", "tag", "l") { model.openTagPicker() }
                }
                GridRow {
                    action("Odložiť…", "clock", "h") { model.openSnoozePicker() }
                    action("Čakám na odpoveď", "hourglass", "") { model.setFollowUp(due: FollowUpOption.threeDays.date) }
                }
            }
            Button("Zrušiť výber") { model.selection = [] }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func action(_ title: String, _ symbol: String, _ key: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.callout)
                Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .frame(width: 110, height: 76)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Subject, a link to the thread note, and chips for the folder and tags (× removes them).
private struct ThreadTitle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.messages.last?.subject.baseSubject.nonEmpty ?? "(bez predmetu)")
                    .font(.system(size: 22, weight: .bold))
                    .textSelection(.enabled)
                Button { model.openThreadNote() } label: {
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Otvoriť poznámku vlákna")
            }
            HStack(spacing: 6) {
                if let folder = folderChip {
                    Chip(title: folder.title, onRemove: folder.remove)
                }
                if let threadID = model.selectedThreadID {
                    ForEach(model.selectedThread?.tags ?? [], id: \.self) { tag in
                        TagPill(name: tag) { model.setTag(tag, false, threadID: threadID) }
                    }
                }
                Button { model.openTagPicker() } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Pridať štítok\(model.shortcutHint(.tag))")
                if model.settings.accounts.count > 1, let accountID = model.messages.last?.accountID,
                   let account = model.account(accountID) {
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(model.accountColor(accountID)).frame(width: 7, height: 7)
                        Text(model.accountTitle(account)).help(account.email)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The folder the thread is shown in; × on "Doručená pošta" archives it.
    private var folderChip: (title: String, remove: (() -> Void)?)? {
        switch model.filter {
        case .inbox: ("Doručená pošta", { model.archiveSelected() })
        case .archive: ("Archív", nil)
        case .sent: ("Odoslané", nil)
        case .trash: ("Kôš", nil)
        case .junk: ("Spam", nil)
        case .folder(let name): (model.folderName(name), nil)
        default: nil
        }
    }
}

/// Rounded label with an optional × (folder chip under the subject).
private struct Chip: View {
    let title: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Archivovať")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Set by a thread window: the card's actions then work on that thread instead of the main selection.
struct ThreadWindowContext {
    let threadID: String
    let messages: [StoredMessage]
}

private struct ThreadWindowContextKey: EnvironmentKey {
    static let defaultValue: ThreadWindowContext? = nil
}

extension EnvironmentValues {
    var threadWindowContext: ThreadWindowContext? {
        get { self[ThreadWindowContextKey.self] }
        set { self[ThreadWindowContextKey.self] = newValue }
    }
}

struct MessageCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.threadWindowContext) private var windowContext
    let message: StoredMessage
    @State private var expanded: Bool
    @State private var htmlHeight: CGFloat = 60
    @State private var showRecipients = false
    @State private var confirmUnsubscribe = false
    @State private var showPerson = false
    @State private var unsubscribing = false

    init(message: StoredMessage, initiallyExpanded: Bool) {
        self.message = message
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            if expanded {
                content
                if !message.attachments.isEmpty { attachments }
            }
        }
        .padding(.bottom, 6)
    }

    private var sender: String {
        model.isOwn(message.from) ? "Ja" : (message.from?.displayName ?? "Neznámy")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(name: message.from?.displayName ?? "?", address: message.from?.address, emphasized: true, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button { showPerson = true } label: {
                        Text(sender).font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(message.from == nil || model.isOwn(message.from))
                    .help("Všetko s týmto človekom")
                    .popover(isPresented: $showPerson, arrowEdge: .bottom) {
                        if let from = message.from { PersonCard(address: from) }
                    }
                    if let address = message.from?.address, !model.isOwn(message.from) {
                        Text("<\(address)>").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Button { showPerson = true } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.themeAccent)
                        }
                        .buttonStyle(.plain)
                        .help("Karta odosielateľa: všetky vlákna a prílohy s ním")
                    }
                    if expanded { unsubscribeButton }
                }
                if expanded {
                    Button { showRecipients.toggle() } label: {
                        HStack(spacing: 3) {
                            Text(recipientSummary)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showRecipients, arrowEdge: .bottom) { recipientDetails }
                } else {
                    Text(message.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    Text(Self.date(message.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if expanded {
                        Button { model.toggleStar(windowContext.map { [$0.threadID] }) } label: {
                            Image(systemName: message.flagged ? "star.fill" : "star")
                                .foregroundStyle(message.flagged ? Color.yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hviezdička\(model.shortcutHint(.star))")
                    }
                }
                if expanded {
                    HStack(spacing: 14) {
                        Button { model.reply(all: false, in: windowContext?.messages) } label: { Image(systemName: "arrowshape.turn.up.left") }
                            .help("Odpovedať\(model.shortcutHint(.reply))")
                        Button { model.forward(in: windowContext?.messages) } label: { Image(systemName: "arrowshape.turn.up.right") }
                            .help("Preposlať\(model.shortcutHint(.forward))")
                        Menu {
                            Button("Odpovedať všetkým") { model.reply(all: true, in: windowContext?.messages) }
                            Button("Uložiť vlákno do Obsidianu") { model.exportSelectedToObsidian(threadID: windowContext?.threadID) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Odhlásiť z odberu" for newsletters (List-Unsubscribe), "Odhlásené" afterwards.
    @ViewBuilder
    private var unsubscribeButton: some View {
        if let date = model.isUnsubscribed(message) {
            Label("Odhlásené", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .help("Odhlásené z odberu \(date.formatted(date: .abbreviated, time: .omitted))")
        } else if let info = model.unsubscribeInfo(for: message), let method = info.preferred {
            Button {
                confirmUnsubscribe = true
            } label: {
                HStack(spacing: 4) {
                    if unsubscribing { ProgressView().controlSize(.mini) }
                    Text("Odhlásiť z odberu")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .disabled(unsubscribing)
            .confirmationDialog("Odhlásiť sa z odberu \(message.from?.displayName ?? "")?", isPresented: $confirmUnsubscribe) {
                Button("Odhlásiť a archivovať") {
                    unsubscribing = true
                    Task {
                        await model.unsubscribe(from: message)
                        unsubscribing = false
                    }
                }
            } message: {
                Text(Self.unsubscribeExplanation(method))
            }
        }
    }

    static func unsubscribeExplanation(_ method: UnsubscribeInfo.Method) -> String {
        switch method {
        case .oneClick(let url): "Mailmule pošle odhlásenie priamo odosielateľovi (\(url.host() ?? "")), bez otvárania stránky."
        case .email(let address, _, _): "Mailmule pošle odhlasovací e-mail na \(address)."
        case .website(let url): "Otvorí sa stránka \(url.host() ?? "") na dokončenie odhlásenia."
        }
    }

    /// "Pre mňa" when the message was sent only to one of your accounts, otherwise the names.
    private var recipientSummary: String {
        let recipients = message.to + message.cc
        if !recipients.isEmpty && recipients.allSatisfy({ model.isOwn($0) }) { return "Pre mňa" }
        let names = recipients.map { model.isOwn($0) ? "mňa" : $0.displayName }
        return "Pre " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " a ďalších \(names.count - 3)" : "")
    }

    private var recipientDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            detailRow("Od", [message.from].compactMap { $0 })
            detailRow("Komu", message.to)
            if !message.cc.isEmpty { detailRow("Kópia", message.cc) }
            GridRow {
                Text("Dátum").foregroundStyle(.secondary)
                Text(message.date.formatted(date: .long, time: .shortened))
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(14)
    }

    private func detailRow(_ label: String, _ addresses: [EmailAddress]) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(addresses, id: \.self) { address in
                    Text(address.name.map { "\($0) <\(address.address)>" } ?? address.address)
                }
            }
        }
    }

    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Dnes \(time)" }
        if calendar.isDateInYesterday(date) { return "Včera \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).year()) + " \(time)"
    }

    @ViewBuilder
    private var content: some View {
        if let invite = model.mime(for: message)?.invite {
            InviteCard(invite: invite, message: message)
        }
        if let warning = model.senderWarning(for: message) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pozor, odosielateľ môže byť podvrhnutý").font(.system(size: 12, weight: .semibold))
                    Text(warning).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help("Vypnete v Nastaveniach → Súkromie")
        }
        let display = message.hasHTML ? model.displayHTML(for: message) : nil
        let allowRemote = model.remoteImagesAllowed(for: message)
        if let display, display.hasRemoteImages, !allowRemote {
            remoteImagesBanner
        }
        let rendered = display.map { model.renderedHTML(for: $0, key: message.key, allowRemote: allowRemote) }
        if let rendered, rendered.trackers > 0 {
            Label(rendered.trackers == 1 ? "Zablokovaný 1 sledovací pixel" : "Zablokované sledovacie pixely: \(rendered.trackers)",
                  systemImage: "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Neviditeľné obrázky, ktoré odosielateľovi oznamujú, že si mail otvoril. Vypneš v Nastaveniach → Písanie.")
        }
        Group {
            if let display, let rendered {
                HTMLView(html: rendered.html, allowRemote: allowRemote, height: $htmlHeight)
                    .frame(height: htmlHeight)
                    .onAppear {
                        if display.missingInlineImages > 0 { model.downloadInlineImages(for: message) }
                    }
            } else {
                Text(message.bodyText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, message.hasHTML ? .light : .light)
    }

    private var remoteImagesBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("Obrázky z internetu sú zablokované, aby odosielateľ nevidel, že si mail otvoril.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Načítať obrázky") { model.loadRemoteImages(for: message, always: false) }
            if let address = message.from?.address {
                Button("Vždy od \(address)") { model.loadRemoteImages(for: message, always: true) }
                    .help("Obrázky od tohto odosielateľa sa budú načítavať automaticky (zrušíš v Nastaveniach → Písanie)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachmentInfo(for: message), id: \.filename) { attachment in
                    Button {
                        model.previewAttachments(in: message, startingAt: attachment.filename)
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: attachment.mimeType) ?? .data))
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Náhľad (medzerník) · pravý klik: otvoriť, uložiť")
                    .contextMenu {
                        Button("Náhľad") { model.previewAttachments(in: message, startingAt: attachment.filename) }
                        Button("Otvoriť v aplikácii") { model.openAttachment(attachment.filename, in: message) }
                        Divider()
                        Button("Uložiť do Stiahnutých") { model.saveAttachment(attachment.filename, in: message, toDownloads: true) }
                        Button("Uložiť ako…") { model.saveAttachment(attachment.filename, in: message, toDownloads: false) }
                    }
                }
            }
        }
    }
}

/// Reply field under the thread: write and send without opening the editor (⌘↩),
/// with one-click suggested replies.
private struct QuickReplyBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private static let suggestions = ["Ďakujem, pozriem sa na to.", "Môžete poslať viac informácií?", "Vyriešim to dnes."]
    private static let moreSuggestions = ["Ďakujem, rozumiem.", "Ozvem sa zajtra.", "Posielam v prílohe.",
                                          "Môžeme si zavolať?", "Súhlasím.", "Potvrdzujem prijatie."]

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let account = model.messages.last.flatMap { model.account($0.accountID) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                Text(String((account?.name ?? "Ja").prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background((account.map { model.accountColor($0.id) } ?? .accentColor).gradient, in: Circle())
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Odpovedať alebo preposlať…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .focused($focused)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            send(archive: model.settings.archiveOnReply)
                            return .handled
                        }
                    Button { model.expandQuickReply(text); text = "" } label: { Image(systemName: "paperclip") }
                        .help("Pridať prílohu (otvorí editor)")
                    Button { focused = true; NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling") }
                        .help("Emoji")
                    Button { model.expandQuickReply(text); text = "" } label: { Image(systemName: "textformat") }
                        .help("Formátovanie (otvorí editor)")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
                sendButton
            }
            HStack(spacing: 8) {
                if model.settings.assistantEnabled { assistantChip }
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    suggestionChip(suggestion)
                }
                Menu {
                    ForEach(Self.moreSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { use(suggestion) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.leading, 42)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .themedChrome()
        .onChange(of: model.selectedThreadID) { text = "" }
    }

    /// Blue send button with a menu: send and archive, or reply to all in the editor.
    private var sendButton: some View {
        HStack(spacing: 0) {
            Button { send(archive: model.settings.archiveOnReply) } label: {
                Image(systemName: sending ? "hourglass" : "paperplane.fill")
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 36)
            }
            .disabled(sending || isEmpty)
            .help("Odoslať (⌘↩)")
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 20)
            Menu {
                if model.settings.archiveOnReply {
                    Button("Odoslať a archivovať") { send(archive: true) }.disabled(isEmpty)
                    Button("Odoslať a ponechať v Prijatých") { send(archive: false) }.disabled(isEmpty)
                } else {
                    Button("Odoslať") { send(archive: false) }.disabled(isEmpty)
                    Button("Odoslať a archivovať") { send(archive: true) }.disabled(isEmpty)
                }
                Menu("Odoslať a pripomenúť, ak neodpovie") {
                    ForEach(FollowUpOption.allCases, id: \.self) { option in
                        Button("\(option.title) – \(SnoozeOption.describe(option.date))") {
                            send(archive: model.settings.archiveOnReply, followUp: option.date)
                        }
                    }
                }
                .disabled(isEmpty)
                Divider()
                Button("Odpovedať všetkým v editore…") { model.reply(all: true) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 36)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .background((isEmpty ? Color.themeAccent.opacity(0.45) : Color.themeAccent), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @State private var suggesting = false

    /// "Navrhnúť odpoveď": the local model writes a draft into the field.
    private var assistantChip: some View {
        Button { suggest(confirmed: false) } label: {
            HStack(spacing: 5) {
                if suggesting {
                    ProgressView().controlSize(.mini)
                    Text(AssistantStatus.text(model.localModel.state) ?? "Píšem…")
                } else {
                    Image(systemName: "sparkles")
                    Text("Navrhnúť odpoveď")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.themeAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.themeAccent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(suggesting)
        .help("Návrh odpovede napíše jazykový model priamo v tomto Macu; text vlákna nikam neodchádza.")
        .onChange(of: model.replySuggestionRequest) { suggest(confirmed: true) }
    }

    private func suggest(confirmed: Bool) {
        guard !suggesting else { return }
        suggesting = true
        let before = text
        Task {
            let ok = await model.suggestReply(confirmed: confirmed) { draft in
                text = draft
            }
            if !ok && text.isEmpty { text = before }
            suggesting = false
            focused = true
        }
    }

    private func suggestionChip(_ suggestion: String) -> some View {
        Button { use(suggestion) } label: {
            Text(suggestion)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func use(_ suggestion: String) {
        text = isEmpty ? suggestion : text + " " + suggestion
        focused = true
    }

    private func send(archive: Bool, followUp: Date? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        Task {
            if await model.quickReply(body, archive: archive, followUp: followUp) {
                text = ""
            }
            sending = false
        }
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hue: Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360, saturation: 0.45, brightness: 0.7), in: Circle())
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}


/// The thread summary from the local model, above the messages.
private struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        let text = model.summaries[threadID] ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Súhrn", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.themeAccent)
                if model.summarizing == threadID {
                    ProgressView().controlSize(.mini)
                    if let status = AssistantStatus.text(model.localModel.state) {
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.summaryOutdated[threadID] == true && model.summarizing != threadID {
                    Text("Pribudli nové správy").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Aktualizovať") { model.summarizeSelectedThread() }
                        .controlSize(.small)
                } else if model.summarizing != threadID && !text.isEmpty {
                    Button { model.summarizeSelectedThread() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Vytvoriť súhrn znova")
                }
                Button { model.summaries[threadID] = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Skryť súhrn (ostane uložený, ✨ ho ukáže znova)")
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Vytvorené v tomto Macu modelom \(model.settings.assistantModel.title.components(separatedBy: " –").first ?? ""). Môže obsahovať chyby.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color.themeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.themeAccent.opacity(0.25)))
    }
}

/// Human-readable progress of the local model, while it is not yet writing.
enum AssistantStatus {
    @MainActor static func text(_ state: LocalModel.State) -> String? {
        switch state {
        case .downloading(let fraction): "Sťahujem model… \(Int(fraction * 100)) %"
        case .loading: "Načítavam model…"
        case .failed(let message): "Chyba: \(message)"
        case .idle, .ready, .generating: nil
        }
    }
}
