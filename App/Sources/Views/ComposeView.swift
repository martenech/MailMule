import AppKit
import MailmuleKit
import SwiftUI
import UniformTypeIdentifiers

enum ComposeField { case to, cc, subject }

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismissSheet
    @Environment(\.dismissWindow) private var dismissWindow
    /// Shown in a window of its own rather than as a sheet over the main window.
    let inWindow: Bool
    @State private var draft: ComposeDraft
    @State private var preview = false
    @State private var sending = false
    @State private var previewHeight: CGFloat = 300
    @State private var confirmMissingAttachment = false
    /// The user changed something, so the message is worth keeping as a draft.
    @State private var dirty = false
    /// Sent or discarded: nothing to save when the sheet closes.
    @State private var finished = false
    @State private var autosave: Task<Void, Never>?
    @State private var showScheduleCustom = false
    @State private var scheduleDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var editor = MarkdownEditorController()
    @FocusState private var focus: ComposeField?

    /// Largest total attachment size most providers accept (Gmail: 25 MB including encoding overhead).
    private static let attachmentLimit = 18 * 1024 * 1024

    init(draft: ComposeDraft, inWindow: Bool = false) {
        _draft = State(initialValue: draft)
        self.inWindow = inWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            if let scheduledAt = draft.scheduledAt {
                HStack {
                    Label("Naplánované na \(SnoozeOption.describe(scheduledAt))", systemImage: "calendar.badge.clock")
                    Spacer()
                    Button("Zrušiť plán") { draft.scheduledAt = nil }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.themeAccent.opacity(0.12))
            }
            header
            Divider()
            formattingBar
            Divider()
            if preview {
                ScrollView {
                    HTMLView(html: MarkdownRenderer.emailDocument(from: draft.body), height: $previewHeight)
                        .frame(height: previewHeight)
                }
            } else {
                MarkdownEditor(text: $draft.body, controller: editor,
                               onFiles: addFiles,
                               onPastedFile: { name, data in draft.attachments.append(OutgoingAttachment(filename: name, data: data)) })
            }
            if !draft.attachments.isEmpty {
                Divider()
                attachmentList
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 560)
        .onAppear {
            model.refreshAddressBook()
            if draft.to.isEmpty {
                focus = .to
            } else if draft.subject.isEmpty {
                focus = .subject
            } else {
                // Replies start above the quoted text.
                DispatchQueue.main.async { editor.focus(atStart: true) }
            }
        }
        .onChange(of: draft.accountID) { old, new in
            // Switching the sender swaps the signature too, unless it was edited.
            let kind = ComposeKind(draft)
            let previous = model.signatureBlock(old, kind: kind)
            if !previous.isEmpty, let range = draft.body.range(of: previous) {
                draft.body.replaceSubrange(range, with: model.signatureBlock(new, kind: kind))
            } else if previous.isEmpty, draft.inReplyTo == nil, draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.body = model.signatureBlock(new, kind: kind)
            }
        }
        .onChange(of: draft) {
            dirty = true
            scheduleAutosave()
        }
        .onDisappear {
            autosave?.cancel()
            if dirty && !finished { model.saveDraft(draft, upload: true) }
        }
        .confirmationDialog("Spomínaš prílohu, ale žiadnu si nepriložil.", isPresented: $confirmMissingAttachment) {
            Button("Odoslať aj tak") { send() }
            Button("Priložiť súbor…") { pickFiles() }
            Button("Zrušiť", role: .cancel) {}
        }
    }

    private var header: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            if model.settings.accounts.count > 1 {
                GridRow {
                    label("Od")
                    Picker("", selection: $draft.accountID) {
                        ForEach(model.settings.accounts) { account in
                            Text(model.hasAccountLabel(account)
                                 ? "\(model.accountTitle(account)) – \(account.name) <\(account.email)>"
                                 : "\(account.name) <\(account.email)>").tag(account.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            // Suggestion lists float over the rows below, so earlier rows draw on top.
            GridRow {
                label("Komu")
                AddressField(placeholder: "meno alebo adresa…", text: $draft.to, focus: $focus, field: .to)
            }
            .zIndex(2)
            GridRow {
                label("Kópia")
                AddressField(placeholder: "", text: $draft.cc, focus: $focus, field: .cc)
            }
            .zIndex(1)
            GridRow {
                label("Predmet")
                TextField("", text: $draft.subject).focused($focus, equals: .subject)
            }
        }
        .textFieldStyle(.plain)
        .padding(16)
        .zIndex(1)
    }

    private var formattingBar: some View {
        HStack(spacing: 2) {
            FormatButton(symbol: "bold", help: "Tučné (⌘B)") { editor.toggleWrap("**") }
            FormatButton(symbol: "italic", help: "Kurzíva (⌘I)") { editor.toggleWrap("*") }
            FormatButton(symbol: "strikethrough", help: "Prečiarknuté") { editor.toggleWrap("~~") }
            FormatButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Kód") { editor.toggleWrap("`") }
            Divider().frame(height: 16).padding(.horizontal, 4)
            FormatButton(symbol: "textformat.size", help: "Nadpis") { editor.toggleLinePrefix(.heading) }
            FormatButton(symbol: "list.bullet", help: "Zoznam") { editor.toggleLinePrefix(.bullet) }
            FormatButton(symbol: "list.number", help: "Číslovaný zoznam") { editor.toggleLinePrefix(.numbered) }
            FormatButton(symbol: "text.quote", help: "Citácia") { editor.toggleLinePrefix(.quote) }
            FormatButton(symbol: "link", help: "Odkaz (⌘K)") { editor.insertLink() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            FormatButton(symbol: "paperclip", help: "Priložiť súbor (⌘⇧A)") { pickFiles() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Spacer()
            Toggle(isOn: $preview) {
                Label("Náhľad", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Náhľad odoslaného e-mailu (⌘⇧P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .buttonStyle(.borderless)
        .disabled(sending)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var attachmentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: attachment.mimeType) ?? .data))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(attachment.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text(dirty ? "Koncept sa ukladá automaticky · ⌘↩ odoslať" : "Markdown · ⌘B ⌘I ⌘K · pretiahni súbory do textu · ⌘↩ odoslať")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if totalAttachmentSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(totalAttachmentSize), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(totalAttachmentSize > Self.attachmentLimit ? .red : .secondary)
            }
            Button("Zahodiť", role: .destructive) {
                finished = true
                model.discardDraft(draft.id)
                close()
            }
            .help("Zmazať koncept")
            if !inWindow {
                Button {
                    // Hand the message over to a window; the sheet closes without saving over it.
                    finished = true
                    let current = draft
                    close()
                    model.presentCompose(current, fromWindow: true)
                } label: { Image(systemName: "macwindow.on.rectangle") }
                .help("Otvoriť v samostatnom okne")
            }
            Button("Zavrieť") { close() }
                .keyboardShortcut(.cancelAction)
                .help("Zavrieť a ponechať ako koncept (Esc)")
            Button {
                if mentionsAttachment && draft.attachments.isEmpty {
                    confirmMissingAttachment = true
                } else {
                    send()
                }
            } label: {
                if sending { ProgressView().controlSize(.small) } else { Text("Odoslať") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(sending || totalAttachmentSize > Self.attachmentLimit)
            Menu {
                Menu("Odoslať a pripomenúť, ak neodpovie") {
                    ForEach(FollowUpOption.allCases, id: \.self) { option in
                        Button("\(option.title) – \(SnoozeOption.describe(option.date))") { send(followUp: option.date) }
                    }
                }
                Divider()
                Section("Odoslať neskôr") {
                    ForEach(SnoozeOption.presets()) { option in
                        Button("\(option.title) – \(SnoozeOption.describe(option.date))") { schedule(at: option.date) }
                    }
                    Button("Vlastný čas…") { showScheduleCustom = true }
                }
            } label: {
                Image(systemName: "calendar.badge.clock")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Odoslať neskôr alebo s pripomienkou")
            .disabled(sending)
            .popover(isPresented: $showScheduleCustom, arrowEdge: .top) {
                VStack(alignment: .trailing, spacing: 12) {
                    DatePicker("", selection: $scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    Button("Naplánovať na \(SnoozeOption.describe(scheduleDate))") {
                        showScheduleCustom = false
                        schedule(at: scheduleDate)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
            }
        }
        .padding(12)
    }

    private func close() {
        if inWindow { dismissWindow() } else { dismissSheet() }
    }

    private var totalAttachmentSize: Int {
        draft.attachments.reduce(0) { $0 + $1.data.count }
    }

    /// True when the new text (not the quoted original) talks about an attachment.
    private var mentionsAttachment: Bool {
        let ownText = draft.body.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }.joined(separator: " ")
        return ownText.range(of: #"(?i)(príloh|priloh|priklad|prikladám|v prílohe|attach)"#, options: .regularExpression) != nil
    }

    private func send(followUp: Date? = nil) {
        autosave?.cancel()
        Task {
            sending = true
            if await model.send(draft, followUp: followUp) {
                finished = true
                close()
            }
            sending = false
        }
    }

    /// Hands the message to scheduled send and closes the editor.
    private func schedule(at date: Date) {
        guard !AddressParser.parseList(draft.to).isEmpty else {
            model.errorMessage = "Doplň aspoň jedného príjemcu."
            return
        }
        autosave?.cancel()
        finished = true
        model.scheduleSend(draft, at: date)
        close()
    }

    /// Saves the draft a second after the last change.
    private func scheduleAutosave() {
        autosave?.cancel()
        let snapshot = draft
        autosave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !finished else { return }
            model.saveDraft(snapshot)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            do {
                draft.attachments.append(try OutgoingAttachment(contentsOf: url))
            } catch {
                model.errorMessage = "Súbor \(url.lastPathComponent) sa nepodarilo načítať: \(error.localizedDescription)"
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .trailing)
    }
}

struct FormatButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
        }
        .help(help)
    }
}
