import AppKit
import MailmuleKit
import SwiftUI

/// Disk usage of the mail vault by kind of file.
struct StorageUsage: Sendable {
    var messages: Int64 = 0
    var notes: Int64 = 0
    var drafts: Int64 = 0
    var index: Int64 = 0
    var freeOnDisk: Int64?

    var total: Int64 { messages + notes + drafts + index }

    static func measure(vault: URL) -> StorageUsage {
        var usage = StorageUsage()
        let accounts = vault.appending(path: "accounts")
        let accountDirs = (try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
        for dir in accountDirs {
            usage.messages += size(of: dir.appending(path: "raw"))
        }
        usage.notes = size(of: vault.appending(path: "threads"))
        usage.drafts = size(of: vault.appending(path: "drafts"))
        usage.index = size(of: vault.appending(path: ".mailmule"))
        let values = try? vault.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        usage.freeOnDisk = values?.volumeAvailableCapacityForImportantUsage
        return usage
    }

    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

struct StorageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var usage: StorageUsage?
    @State private var counts: [String: Int] = [:]
    @State private var vaultPath = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var confirmRedownload = false
    @State private var confirmRebuild = false

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .storage) {
            SettingsCard("Využitie úložiska", subtitle: "Koľko miesta zaberá pošta v tomto Macu. Na serveri ostáva všetko.", accessory: {
                if let usage {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.format(usage.total)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                        if let free = usage.freeOnDisk {
                            Text("voľné na disku \(Self.format(free))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }) {
                if let usage { usageBar(usage) }
            }

            SettingsCard("Pošta v tomto Macu", subtitle: "Koľko histórie a či aj prílohy sa sťahujú, pre každý účet. Keď limit sprísnite, staršia pošta a prílohy sa z Macu odstránia.") {
                SettingsRows {
                    ForEach(model.settings.accounts) { account in
                        HStack(spacing: 12) {
                            AccountBadge(account: account, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.accountTitle(account)).font(.system(size: 13)).help(account.email)
                                if let count = counts[account.id] {
                                    Text("\(count) správ v Macu").font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Picker("", selection: policy(for: account.id).historyMonths) {
                                Text("Len najnovšie").tag(Int?.some(0))
                                Text("3 mesiace").tag(Int?.some(3))
                                Text("1 rok").tag(Int?.some(12))
                                Text("2 roky").tag(Int?.some(24))
                                Text("5 rokov").tag(Int?.some(60))
                                Text("Celá história").tag(Int?.none)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            Picker("", selection: policy(for: account.id).attachments) {
                                Text("Prílohy vždy").tag(AttachmentPolicy.always)
                                Text("Prílohy na vyžiadanie").tag(AttachmentPolicy.onDemand)
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                    }
                }
            }

            SettingsCard("Umiestnenie súborov") {
                SettingsRows {
                    SettingsRow("Mail vault", detail: "Pošta ako .eml a .md súbory, ktoré vlastníte.") {
                        HStack {
                            TextField("", text: $vaultPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 160, maxWidth: 260)
                            Button("Zmeniť…") { if let path = VaultForm.pickFolder() { vaultPath = path } }
                                .fixedSize()
                            if vaultPath != model.settings.mailVaultPath {
                                Button("Použiť") {
                                    model.settings.mailVaultPath = vaultPath
                                    Task { await model.configure() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    SettingsRow("Obsidian trezor", detail: "Kam sa ukladajú vlákna (o) a prílohy.") {
                        HStack {
                            TextField("", text: $model.settings.obsidianVaultPath, prompt: Text("nevybraný"))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 160, maxWidth: 260)
                            let detected = AppSettings.detectObsidianVaults()
                            if !detected.isEmpty {
                                Menu("Nájdené") {
                                    ForEach(detected, id: \.self) { path in
                                        Button(path) { model.settings.obsidianVaultPath = path }
                                    }
                                }
                                .fixedSize()
                            }
                            Button("Zmeniť…") {
                                if let path = VaultForm.pickFolder() { model.settings.obsidianVaultPath = path }
                            }
                            .fixedSize()
                        }
                    }
                    SettingsRow("Priečinok v trezore") {
                        TextField("", text: $model.settings.obsidianFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    SettingsToggle("Po uložení otvoriť poznámku v Obsidiane", isOn: $model.settings.openInObsidianAfterExport)
                }
            }

            SettingsCard("Údržba", subtitle: "Pošta je vždy celá na serveri, tieto akcie menia len kópiu v Macu.") {
                HStack(spacing: 10) {
                    Button("Otvoriť vo Finderi") { model.revealVault() }
                    Button(checking ? "Kontrolujem…" : "Skontrolovať databázu") {
                        checking = true
                        Task {
                            checkResult = await model.checkDatabase()
                            checking = false
                        }
                    }
                    .disabled(checking)
                    Button("Stiahnuť všetku poštu znova…") { confirmRedownload = true }
                    Button("Vytvoriť databázu nanovo…") { confirmRebuild = true }
                    Spacer()
                }
                if let checkResult {
                    Label(checkResult == "ok" ? "Databáza je v poriadku." : "Databáza má chyby: \(checkResult). Pomôže „Vytvoriť databázu nanovo“.",
                          systemImage: checkResult == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(checkResult == "ok" ? Color.green : Color.orange)
                }
            }
        }
        .task { await refresh() }
        .onAppear { vaultPath = model.settings.mailVaultPath }
        .confirmationDialog("Vytvoriť databázu nanovo?", isPresented: $confirmRebuild) {
            Button("Vytvoriť nanovo", role: .destructive) {
                Task {
                    await model.rebuildIndex()
                    checkResult = nil
                    await refresh()
                }
            }
        } message: {
            Text("Len pri poškodenej databáze. Zoznam správ sa načíta znova zo servera; stratia sa časy odložení, pripomienky „bez odpovede“ a AI súhrny. Stará databáza sa odloží vedľa (index.broken-…). Súbory pošty, koncepty a nastavenia ostanú.")
        }
        .confirmationDialog("Stiahnuť všetku poštu znova?", isPresented: $confirmRedownload) {
            Button("Vymazať a stiahnuť znova", role: .destructive) {
                Task {
                    for account in model.settings.accounts { await model.resetAccount(account.id) }
                    await refresh()
                }
            }
        } message: {
            Text("Z Macu sa zmaže stiahnutá pošta všetkých účtov a stiahne sa znova podľa nastavení. Koncepty a poznámky v Obsidiane ostanú.")
        }
    }

    private func refresh() async {
        let vault = model.settings.mailVaultURL
        usage = await Task.detached { StorageUsage.measure(vault: vault) }.value
        counts = await model.messageCounts()
    }

    private func usageBar(_ usage: StorageUsage) -> some View {
        let parts: [(String, Int64, Color)] = [
            ("Správy a prílohy", usage.messages, .blue),
            ("Poznámky vlákien", usage.notes, .purple),
            ("Index a vyhľadávanie", usage.index, .green),
            ("Koncepty", usage.drafts, .orange),
        ]
        let total = max(Double(usage.total), 1)
        return VStack(alignment: .leading, spacing: 14) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { _, size, color in
                        if size > 0 {
                            color.frame(width: max(3, proxy.size.width * Double(size) / total))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())
            .background(Color.primary.opacity(0.06), in: Capsule())
            HStack(alignment: .top) {
                ForEach(parts, id: \.0) { title, size, color in
                    HStack(alignment: .top, spacing: 7) {
                        Circle().fill(color).frame(width: 9, height: 9).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 12))
                            Text(Self.format(size)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func policy(for accountID: String) -> Binding<SyncPolicy> {
        Binding(get: { model.settings.syncPolicies[accountID] ?? .init() },
                set: { model.updatePolicy(accountID: accountID, $0) })
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
