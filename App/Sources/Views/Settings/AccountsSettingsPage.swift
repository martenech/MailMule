import MailmuleKit
import SwiftUI

struct AccountsSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AccountDraft?
    @State private var confirmRemove: Account?
    @State private var confirmReset: Account?
    @State private var renaming: Account?
    @State private var defaultRefresh = 0
    @State private var newLabel = ""

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .accounts) {
            SettingsCard("Pripojené účty", subtitle: "Pridajte, upravte alebo dočasne vypnite e-mailové účty. Vypnutý účet sa nesynchronizuje ani neupozorňuje, jeho pošta ostáva v Macu.") {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.accounts.enumerated()), id: \.element.id) { offset, account in
                        if offset > 0 { Divider() }
                        accountRow(account)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                HStack {
                    Button("Pridať účet") { editing = AccountDraft() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }

            SettingsCard("Predvolená e-mailová aplikácia", subtitle: "Odkazy mailto: v Safari, PDF a iných aplikáciách otvoria novú správu v tejto aplikácii. Vo Finderi je navyše pravý klik → Služby → Poslať e-mailom v Mailmule.") {
                SettingsRow(model.isDefaultMailApp ? "Mailmule je predvolená pošta" : "Odkazy mailto: teraz otvára iná aplikácia",
                            symbol: model.isDefaultMailApp ? "checkmark.seal.fill" : "envelope.badge") {
                    if !model.isDefaultMailApp {
                        Button("Nastaviť Mailmule") {
                            Task {
                                await model.makeDefaultMailApp()
                                defaultRefresh += 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .id(defaultRefresh)
            }

            SettingsCard("Odosielateľ", subtitle: "Z ktorého účtu sa píše nová správa. Pri písaní sa dá zmeniť v poli Od.") {
                SettingsRows {
                    SettingsRow("Predvolený odosielateľ") {
                        Picker("", selection: $model.settings.defaultSender) {
                            Text("Podľa účtu vybraného v bočnom paneli").tag(DefaultSender.currentAccount)
                            Text("Vždy primárny účet").tag(DefaultSender.primary)
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                    SettingsRow("Primárny účet", detail: "Odosiela, keď je vybraté „Všetky účty“.") {
                        Picker("", selection: primaryBinding) {
                            ForEach(model.settings.accounts) { Text(model.accountTitle($0)).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                }
            }

            SettingsCard("Synchronizácia", subtitle: "Nová pošta v Doručenej prichádza okamžite (IMAP IDLE). Ostatné priečinky sa kontrolujú v intervale.") {
                SettingsRows {
                    SettingsRow("Kontrolovať ostatné priečinky", symbol: "arrow.triangle.2.circlepath") {
                        Picker("", selection: $model.settings.syncIntervalMinutes) {
                            Text("Každú minútu").tag(1)
                            Text("Každých 5 minút").tag(5)
                            Text("Každých 15 minút").tag(15)
                            Text("Každých 30 minút").tag(30)
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                    SettingsToggle("Návrhy adries z Kontaktov", detail: "Pri písaní ponúkať aj adresy z aplikácie Kontakty v macOS.",
                                   symbol: "person.crop.circle", isOn: $model.settings.suggestFromContacts)
                }
                Text("Koľko histórie a či aj prílohy sa sťahujú, nastavíte pri každom účte cez … → Upraviť.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { draft in
            AccountEditor(draft: draft)
        }
        .confirmationDialog("Odstrániť účet \(confirmRemove?.email ?? "")?", isPresented: removeBinding, presenting: confirmRemove) { account in
            Button("Odstrániť", role: .destructive) { Task { await model.removeAccount(account.id) } }
        } message: { _ in
            Text("Z Mailmule sa odstráni účet aj jeho stiahnutá pošta. Na serveri sa nič nezmení.")
        }
        .confirmationDialog("Vymazať stiahnutú poštu účtu \(confirmReset?.email ?? "")?", isPresented: resetBinding, presenting: confirmReset) { account in
            Button("Vymazať a stiahnuť znova", role: .destructive) { Task { await model.resetAccount(account.id) } }
        } message: { _ in
            Text("Z tohto Macu sa zmažú stiahnuté e-maily a poznámky vlákien tohto účtu a pošta sa stiahne znova. Na serveri sa nič nezmení; koncepty a poznámky v Obsidiane ostanú.")
        }
        .alert("Názov účtu", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { account in
            TextField("napr. Práca, Osobné", text: $newLabel)
            Button("Uložiť") {
                let label = newLabel.trimmingCharacters(in: .whitespaces)
                model.settings.accountLabels[account.id] = label.isEmpty ? nil : label
            }
            Button("Zrušiť", role: .cancel) {}
        } message: { account in
            Text("Zobrazí sa v Mailmule namiesto \(account.email). Príjemcovia ho nevidia; prázdne pole vráti adresu.")
        }
        .onAppear { openAddFormIfRequested() }
        .onChange(of: model.addAccountRequested) { openAddFormIfRequested() }
    }

    private func openAddFormIfRequested() {
        guard model.addAccountRequested else { return }
        model.addAccountRequested = false
        editing = AccountDraft()
    }

    private func accountRow(_ account: Account) -> some View {
        let enabled = !model.settings.disabledAccounts.contains(account.id)
        let isPrimary = model.primaryAccountID == account.id && model.settings.accounts.count > 1
        return HStack(spacing: 12) {
            AccountBadge(account: account)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountTitle(account)).font(.system(size: 13, weight: .medium))
                Text(model.hasAccountLabel(account) ? account.email
                     : (account.imapHost == "imap.gmail.com" ? "Gmail" : account.imapHost))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            status(account, enabled: enabled)
            if isPrimary {
                Text("Primárny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.themeAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.themeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            Toggle("", isOn: Binding(get: { enabled }, set: { model.setAccountEnabled(account.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(enabled ? "Vypnúť synchronizáciu účtu" : "Zapnúť synchronizáciu účtu")
            Menu {
                Button("Premenovať…") {
                    newLabel = model.settings.accountLabels[account.id] ?? ""
                    renaming = account
                }
                Button("Upraviť…") {
                    var draft = AccountDraft(account, policy: model.settings.syncPolicies[account.id] ?? .init())
                    draft.label = model.settings.accountLabels[account.id] ?? ""
                    editing = draft
                }
                if model.settings.accounts.count > 1 {
                    Button("Nastaviť ako primárny") { model.settings.primaryAccountID = account.id }
                        .disabled(isPrimary)
                }
                Divider()
                Button("Vymazať stiahnutú poštu a začať odznova…") { confirmReset = account }
                Button("Odstrániť účet…", role: .destructive) { confirmRemove = account }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func status(_ account: Account, enabled: Bool) -> some View {
        if !enabled {
            Label("Vypnutý", systemImage: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if let error = model.syncErrors[account.id] {
            Label("Chyba synchronizácie", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help(error)
        } else if let date = model.accountLastSync[account.id] {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Synchronizované \(date.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Synchronizujem…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    private var primaryBinding: Binding<String?> {
        Binding(get: { model.primaryAccountID }, set: { model.settings.primaryAccountID = $0 })
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })
    }

    private var resetBinding: Binding<Bool> {
        Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } })
    }
}

/// Gmail "G" or the account's initial in its color.
struct AccountBadge: View {
    @Environment(AppModel.self) private var model
    let account: Account
    var size: CGFloat = 36

    var body: some View {
        let isGmail = account.imapHost == "imap.gmail.com"
        Text(isGmail ? "G" : String(account.email.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(model.accountColor(account.id).gradient, in: Circle())
    }
}

/// Add or edit an account in a sheet.
private struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: AccountDraft
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(draft.originalID == nil ? "Nový účet" : (draft.label.isEmpty ? draft.email : draft.label)) {
                    AccountForm(draft: $draft)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Zrušiť") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.originalID == nil ? "Pridať účet" : "Uložiť") {
                    saving = true
                    Task {
                        await model.saveAccount(draft)
                        saving = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || saving)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }
}

extension AccountDraft: Identifiable {
    var id: String { originalID ?? "new" }
}
