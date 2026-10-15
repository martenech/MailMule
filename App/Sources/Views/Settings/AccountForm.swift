import AppKit
import MailmuleKit
import SwiftUI

struct AccountDraft {
    enum Provider: String, CaseIterable, Identifiable {
        case gmail = "Gmail"
        case imap = "Iný IMAP"
        var id: String { rawValue }
    }

    var originalID: String?
    var provider: Provider = .gmail
    var name = ""
    /// Shown in Mailmule instead of the address ("Práca"); not sent to anyone.
    var label = ""
    var email = ""
    var username = ""
    var imapHost = "imap.gmail.com"
    var imapPort = "993"
    var smtpHost = "smtp.gmail.com"
    var smtpPort = "465"
    var imapSecurity: ConnectionSecurity = .tls
    var smtpSecurity: ConnectionSecurity = .tls
    var password = ""
    /// New accounts start with a year of mail and attachments on demand; existing ones keep their policy.
    var policy = SyncPolicy(historyMonths: 12, attachments: .onDemand)

    init() {}

    init(_ account: Account) {
        originalID = account.id
        provider = account.imapHost == "imap.gmail.com" ? .gmail : .imap
        name = account.name
        email = account.email
        username = account.username == account.email ? "" : account.username
        imapHost = account.imapHost
        imapPort = String(account.imapPort)
        smtpHost = account.smtpHost
        smtpPort = String(account.smtpPort)
        imapSecurity = account.imapSecurity
        smtpSecurity = account.smtpSecurity
        password = Keychain.password(for: account.id) ?? ""
    }

    init(_ account: Account, policy: SyncPolicy) {
        self.init(account)
        self.policy = policy
    }

    var isValid: Bool {
        !email.isEmpty && email.contains("@") && !password.isEmpty && !imapHost.isEmpty && !smtpHost.isEmpty
            && UInt16(imapPort) != nil && UInt16(smtpPort) != nil
    }

    var account: Account {
        Account(name: name.isEmpty ? email : name, email: email.trimmingCharacters(in: .whitespaces),
                username: username.isEmpty ? nil : username,
                imapHost: imapHost, imapPort: UInt16(imapPort) ?? 993,
                smtpHost: smtpHost, smtpPort: UInt16(smtpPort) ?? 465,
                imapSecurity: provider == .gmail ? .tls : imapSecurity,
                smtpSecurity: provider == .gmail ? .tls : smtpSecurity)
    }
}

struct AccountForm: View {
    @Binding var draft: AccountDraft

    var body: some View {
        Picker("Typ účtu", selection: $draft.provider) {
            ForEach(AccountDraft.Provider.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: draft.provider) {
            if draft.provider == .gmail {
                draft.imapHost = "imap.gmail.com"; draft.imapPort = "993"
                draft.smtpHost = "smtp.gmail.com"; draft.smtpPort = "465"
            }
        }
        TextField("Názov účtu", text: $draft.label, prompt: Text("napr. Práca, Osobné, Firma"))
        Text("Zobrazuje sa v Mailmule namiesto e-mailovej adresy. Príjemcovia ho nevidia.")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField("Meno odosielateľa", text: $draft.name, prompt: Text("Ján Novák"))
        TextField("E-mail", text: $draft.email, prompt: Text("meno@gmail.com"))
        SecureField(draft.provider == .gmail ? "Heslo aplikácie" : "Heslo", text: $draft.password)
        if draft.provider == .gmail {
            Text("Gmail vyžaduje **heslo aplikácie** (nie bežné heslo). Vytvoríš ho na [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords); musíš mať zapnuté dvojstupňové overenie.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            TextField("Používateľské meno", text: $draft.username, prompt: Text("ak sa líši od e-mailu"))
            HStack {
                TextField("IMAP server", text: $draft.imapHost)
                TextField("Port", text: $draft.imapPort).frame(width: 70)
                securityPicker($draft.imapSecurity, port: $draft.imapPort, tls: "993", startTLS: "143")
            }
            HStack {
                TextField("SMTP server", text: $draft.smtpHost)
                TextField("Port", text: $draft.smtpPort).frame(width: 70)
                securityPicker($draft.smtpSecurity, port: $draft.smtpPort, tls: "465", startTLS: "587")
            }
            Text("SSL/TLS šifruje spojenie od začiatku (IMAP 993, SMTP 465). STARTTLS ho zašifruje pred prihlásením (IMAP 143, SMTP 587); bez šifrovania sa Mailmule neprihlási.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        SyncPolicyForm(policy: $draft.policy)
    }

    /// SSL/TLS or STARTTLS; switching moves the port to the usual one when it was the default.
    private func securityPicker(_ security: Binding<ConnectionSecurity>, port: Binding<String>, tls: String, startTLS: String) -> some View {
        Picker("", selection: Binding(get: { security.wrappedValue }, set: { value in
            security.wrappedValue = value
            if port.wrappedValue == tls || port.wrappedValue == startTLS { port.wrappedValue = value == .tls ? tls : startTLS }
        })) {
            Text("SSL/TLS").tag(ConnectionSecurity.tls)
            Text("STARTTLS").tag(ConnectionSecurity.startTLS)
        }
        .labelsHidden()
        .frame(width: 110)
    }
}

/// How much of an account's mail is kept on this Mac.
struct SyncPolicyForm: View {
    @Binding var policy: SyncPolicy

    var body: some View {
        Picker("Sťahovať poštu", selection: $policy.historyMonths) {
            Text("Len najnovšie (300 v priečinku)").tag(Int?.some(0))
            Text("Posledné 3 mesiace").tag(Int?.some(3))
            Text("Posledný rok").tag(Int?.some(12))
            Text("Posledné 2 roky").tag(Int?.some(24))
            Text("Posledných 5 rokov").tag(Int?.some(60))
            Text("Celú históriu").tag(Int?.none)
        }
        Picker("Prílohy", selection: $policy.attachments) {
            Text("Sťahovať vždy").tag(AttachmentPolicy.always)
            Text("Až pri otvorení").tag(AttachmentPolicy.onDemand)
        }
        Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var explanation: String {
        var parts = ["Pošta ostáva celá na serveri; toto určuje len, čo je uložené v tomto Macu."]
        if policy.attachments == .onDemand {
            parts.append("E-maily nad 100 kB sa stiahnu bez príloh; prílohu stiahne otvorenie, export do Obsidianu alebo preposlanie.")
        }
        parts.append("Keď limit sprísniš, staršia pošta a prílohy sa z Macu odstránia.")
        return parts.joined(separator: " ")
    }
}

struct VaultForm: View {
    @Binding var settings: AppSettings
    private let detectedVaults = AppSettings.detectObsidianVaults()

    var body: some View {
        HStack {
            TextField("Mail vault", text: $settings.mailVaultPath)
            Button("Vybrať…") { if let path = Self.pickFolder() { settings.mailVaultPath = path } }
        }
        Text("Priečinok, kde bude pošta uložená ako .eml a .md súbory.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            TextField("Obsidian trezor", text: $settings.obsidianVaultPath, prompt: Text("nevybraný"))
            if !detectedVaults.isEmpty {
                Menu("Nájdené") {
                    ForEach(detectedVaults, id: \.self) { path in
                        Button(path) { settings.obsidianVaultPath = path }
                    }
                }
                .fixedSize()
            }
            Button("Vybrať…") { if let path = Self.pickFolder() { settings.obsidianVaultPath = path } }
        }
        TextField("Priečinok v trezore", text: $settings.obsidianFolder)
        Toggle("Po uložení otvoriť poznámku v Obsidiane", isOn: $settings.openInObsidianAfterExport)
    }

    static func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AccountDraft()
    @State private var settings = AppSettings()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vitaj v Mailmule")
                        .font(.largeTitle.weight(.bold))
                    Text("Pošta ako súbory, ktoré vlastníš. Markdown, klávesnica a Obsidian.")
                        .foregroundStyle(.secondary)
                }
                Form {
                    Section("Účet") { AccountForm(draft: $draft) }
                    Section("Úložisko") { VaultForm(settings: $settings) }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Začať") {
                        Task {
                            settings.accounts = []
                            model.settings = settings
                            await model.saveAccount(draft)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!draft.isValid)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .onAppear { settings = model.settings }
    }
}

/// A miniature of a theme: sidebar, bar and content colors with the accent.
struct ThemeSwatch: View {
    let preset: ThemePreset
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                sidebar.frame(width: 30)
                VStack(spacing: 0) {
                    (preset.chrome ?? Color(nsColor: .windowBackgroundColor)).frame(height: 14)
                    ZStack(alignment: .topLeading) {
                        preset.content ?? (preset.translucent ? Color.gray.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(preset.accent ?? .accentColor).frame(width: 30, height: 6)
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 44, height: 6)
                        }
                        .padding(7)
                    }
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if preset.translucent {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.themeAccent : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1))
            Text(preset.name).font(.callout)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sidebar: some View {
        switch preset.sidebar {
        case .system: Color.gray.opacity(0.18)
        case .mailmule: LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.09, green: 0.10, blue: 0.13)],
                                       startPoint: .top, endPoint: .bottom)
        case .color(let color): color
        }
    }
}

/// A portrait thumbnail in the sidebar background picker.
struct SidebarBackgroundTile: View {
    var url: URL?
    var title: String?
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                    VStack(spacing: 4) {
                        if let symbol { Image(systemName: symbol) }
                        if let title { Text(title).font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.themeAccent : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
