import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case accounts, compose, appearance, notifications, calendar, privacy, storage, rules, assistant, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Účty"
        case .compose: "Písanie"
        case .appearance: "Vzhľad"
        case .notifications: "Oznámenia"
        case .calendar: "Kalendár"
        case .privacy: "Súkromie"
        case .storage: "Úložisko"
        case .rules: "Pravidlá a automatizácie"
        case .assistant: "Asistent"
        case .shortcuts: "Klávesové skratky"
        case .advanced: "Rozšírené"
        }
    }

    var subtitle: String {
        switch self {
        case .accounts: "Spravujte e-mailové účty, synchronizáciu a odosielateľa."
        case .compose: "Nastavte, ako sa majú správy písať, podpisovať a odosielať."
        case .appearance: "Prispôsobte si vzhľad aplikácie, rozloženie a čitateľnosť."
        case .notifications: "Vyberte, kedy a ako vás má aplikácia upozorňovať."
        case .calendar: "Udalosti z Kalendára v Prehľade a pozvánky z pošty."
        case .privacy: "Chráňte sa pred sledovaním a podvodnými správami."
        case .storage: "Pošta ako súbory na vašom Macu: miesto, umiestnenie a údržba."
        case .rules: "Automatizujte triedenie, označovanie a upratovanie pošty."
        case .assistant: "Súhrny vlákien a návrhy odpovedí jazykovým modelom priamo v Macu."
        case .shortcuts: "Celý Mailmule sa dá ovládať z klávesnice."
        case .advanced: "Servisné nástroje, záloha a obnovenie nastavení."
        }
    }

    /// Shorter name for the sidebar.
    var sidebarTitle: String {
        switch self {
        case .rules: "Pravidlá"
        case .shortcuts: "Skratky"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .accounts: "person"
        case .compose: "pencil"
        case .appearance: "paintpalette"
        case .notifications: "bell"
        case .calendar: "calendar"
        case .privacy: "shield"
        case .storage: "folder"
        case .rules: "bolt"
        case .assistant: "sparkles"
        case .shortcuts: "keyboard"
        case .advanced: "gearshape"
        }
    }
}

/// Settings you can search for by name ("podpis", "téma", "zvuk"…), each pointing at its page.
private struct SettingsEntry: Identifiable {
    var id: String { title }
    let category: SettingsCategory
    let title: String
    var keywords = ""

    static let all: [SettingsEntry] = [
        .init(category: .accounts, title: "Pridať účet", keywords: "nový gmail imap"),
        .init(category: .accounts, title: "Premenovať účet", keywords: "názov účtu meno"),
        .init(category: .accounts, title: "Vypnúť účet", keywords: "pozastaviť synchronizáciu"),
        .init(category: .accounts, title: "Heslo a server účtu", keywords: "upraviť imap smtp port heslo aplikácie"),
        .init(category: .accounts, title: "Predvolená e-mailová aplikácia", keywords: "mailto default služby finder"),
        .init(category: .accounts, title: "Predvolený odosielateľ", keywords: "primárny účet od"),
        .init(category: .accounts, title: "Interval synchronizácie", keywords: "kontrolovať priečinky minúty"),
        .init(category: .accounts, title: "Návrhy adries z Kontaktov", keywords: "kontakty doplňovanie"),
        .init(category: .compose, title: "Podpisy", keywords: "podpis"),
        .init(category: .compose, title: "Archivovať po odpovedi", keywords: "odoslaní archív"),
        .init(category: .compose, title: "Zrušiť odoslanie", keywords: "vrátiť undo send"),
        .init(category: .compose, title: "Písať v samostatnom okne", keywords: "okno editor"),
        .init(category: .compose, title: "Formát správ", keywords: "čistý text html formátovaný"),
        .init(category: .compose, title: "Veľkosť písma v editore", keywords: "písmo font"),
        .init(category: .compose, title: "Kontrola pravopisu", keywords: "jazyk slovenčina"),
        .init(category: .appearance, title: "Téma", keywords: "farby tmavý svetlý motív"),
        .init(category: .appearance, title: "Akcentová farba", keywords: "farba zvýraznenie"),
        .init(category: .appearance, title: "Pozadie bočného panela", keywords: "obrázok sidebar"),
        .init(category: .appearance, title: "Kompaktný zoznam", keywords: "hustota riadky"),
        .init(category: .appearance, title: "Ukážka správy v zozname", keywords: "náhľad riadky dĺžka"),
        .init(category: .appearance, title: "Veľké avatary", keywords: "ikony"),
        .init(category: .appearance, title: "Rozloženie 2 alebo 3 stĺpce", keywords: "stĺpce okno"),
        .init(category: .notifications, title: "Upozornenia na nové správy", keywords: "banner notifikácie"),
        .init(category: .notifications, title: "Zvuk upozornenia", keywords: "zvuk"),
        .init(category: .notifications, title: "Počet neprečítaných v Docku", keywords: "dock odznak"),
        .init(category: .notifications, title: "VIP odosielatelia", keywords: "len vip dôležité"),
        .init(category: .notifications, title: "Tichý režim", keywords: "noc nerušiť čas"),
        .init(category: .notifications, title: "Skúšobné upozornenie", keywords: "test povolenie"),
        .init(category: .calendar, title: "Pripojiť Kalendár", keywords: "udalosti google icloud stretnutia prehľad"),
        .init(category: .calendar, title: "Zobrazené kalendáre", keywords: "vybrať kalendár"),
        .init(category: .calendar, title: "Pridávať prijaté pozvánky do Kalendára", keywords: "pozvánka ics"),
        .init(category: .privacy, title: "Obrázky z internetu", keywords: "načítať obrázky sledovanie"),
        .init(category: .privacy, title: "Sledovacie pixely", keywords: "tracker"),
        .init(category: .privacy, title: "Logá firiem pri odosielateľoch", keywords: "avatar logo"),
        .init(category: .privacy, title: "Podozriví odosielatelia", keywords: "podvod phishing varovanie"),
        .init(category: .privacy, title: "Výnimky pre obrázky", keywords: "dôveryhodní domény"),
        .init(category: .storage, title: "Využitie úložiska", keywords: "miesto disk"),
        .init(category: .storage, title: "História a prílohy v Macu", keywords: "sťahovať mesiace prílohy na vyžiadanie"),
        .init(category: .storage, title: "Mail vault", keywords: "priečinok umiestnenie"),
        .init(category: .storage, title: "Obsidian trezor", keywords: "obsidian export"),
        .init(category: .storage, title: "Skontrolovať databázu", keywords: "údržba oprava"),
        .init(category: .rules, title: "Pravidlá", keywords: "automatizácia filter triedenie"),
        .init(category: .rules, title: "Rýchle akcie (gestá)", keywords: "potiahnutie trackpad swipe"),
        .init(category: .rules, title: "Po archivácii označiť ako prečítané", keywords: "archív prečítané"),
        .init(category: .assistant, title: "Asistent", keywords: "ai súhrn model"),
        .init(category: .assistant, title: "Jazykový model", keywords: "qwen stiahnuť zmazať"),
        .init(category: .shortcuts, title: "Klávesové skratky", keywords: "klávesy skratka"),
        .init(category: .advanced, title: "Záznam aplikácie", keywords: "log"),
        .init(category: .advanced, title: "Export a import nastavení", keywords: "záloha preniesť"),
        .init(category: .advanced, title: "Zálohovať poštu", keywords: "zip záloha"),
        .init(category: .advanced, title: "Obnoviť predvolené nastavenia", keywords: "reset"),
        .init(category: .advanced, title: "Odhlásiť všetky účty", keywords: "heslá kľúčenka"),
    ]

    func matches(_ needle: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let haystack = fold(title + " " + keywords + " " + category.title)
        return fold(needle).split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        let needle = query.trimmingCharacters(in: .whitespaces)
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Hľadať…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                if needle.isEmpty {
                    List(SettingsCategory.allCases, selection: Binding(get: { model.settingsCategory },
                                                                       set: { if let value = $0 { model.settingsCategory = value } })) { item in
                        Label(item.sidebarTitle, systemImage: item.symbol)
                            .font(.system(size: 13))
                            .padding(.vertical, 3)
                            .tag(item)
                    }
                } else {
                    let results = SettingsEntry.all.filter { $0.matches(needle) }
                    List {
                        if results.isEmpty {
                            Text("Nič sa nenašlo").foregroundStyle(.secondary)
                        }
                        ForEach(results) { entry in
                            Button {
                                model.settingsCategory = entry.category
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title).font(.system(size: 13))
                                    Label(entry.category.sidebarTitle, systemImage: entry.category.symbol)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 260, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.settingsCategory {
                case .accounts: AccountsSettingsPage()
                case .compose: ComposeSettingsPage()
                case .appearance: AppearanceSettingsPage()
                case .notifications: NotificationSettingsPage()
                case .calendar: CalendarSettingsPage()
                case .privacy: PrivacySettingsPage()
                case .storage: StorageSettingsPage()
                case .rules: RulesSettingsPage()
                case .assistant: AssistantSettingsPage()
                case .shortcuts: ShortcutsSettingsPage()
                case .advanced: AdvancedSettingsPage()
                }
            }
            .navigationTitle("Nastavenia")
        }
        .frame(minWidth: 880, idealWidth: 1000, minHeight: 640, idealHeight: 780)
        .onAppear { if model.addAccountRequested { model.settingsCategory = .accounts } }
        .onChange(of: model.addAccountRequested) { if model.addAccountRequested { model.settingsCategory = .accounts } }
    }
}
