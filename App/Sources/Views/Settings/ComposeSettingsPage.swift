import AppKit
import MailmuleKit
import SwiftUI

struct ComposeSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .compose) {
            SettingsCard {
                SettingsToggle("Po odoslaní odpovede archivovať vlákno",
                               detail: "Platí pri odpovedi z Prijatých. Keď niekto odpovie, vlákno sa vráti do Prijatých. Jednorazovo sa dá zvoliť v ponuke pri tlačidle Odoslať.",
                               isOn: $model.settings.archiveOnReply)
            }

            SettingsCard("Podpisy", subtitle: "Podpis sa vloží nad citovaný text; pri zmene odosielateľa sa vymení. Píše sa v Markdowne, každý riadok ostane riadkom.") {
                ForEach(model.settings.accounts) { account in
                    SignatureEditor(account: account, text: signature(for: account.id))
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                SettingsCard("Formát písania") {
                    SettingsRows {
                        SettingsRow("Formát správ") {
                            Picker("", selection: $model.settings.messageFormat) {
                                Text("Čistý text").tag(MessageFormat.plain)
                                Text("Formátovaný").tag(MessageFormat.formatted)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        SettingsToggle("Písať v samostatnom okne",
                                       detail: "Nová správa a odpoveď sa otvoria v okne, nie ako panel nad poštou. Z panela sa dá kedykoľvek presunúť do okna.",
                                       isOn: $model.settings.composeInWindow)
                        SettingsRow("Zrušiť odoslanie", detail: "Správa počká a dá sa ešte vrátiť do editora (z).") {
                            Picker("", selection: $model.settings.undoSendSeconds) {
                                Text("Vypnuté").tag(0)
                                Text("5 sekúnd").tag(5)
                                Text("10 sekúnd").tag(10)
                                Text("20 sekúnd").tag(20)
                                Text("30 sekúnd").tag(30)
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        SettingsRow("Veľkosť písma v editore") {
                            Picker("", selection: $model.settings.editorFontSize) {
                                Text("Malá (13 px)").tag(13.0)
                                Text("Stredná (14 px)").tag(14.0)
                                Text("Veľká (16 px)").tag(16.0)
                                Text("Najväčšia (18 px)").tag(18.0)
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        SettingsRow("Kontrola pravopisu") {
                            Picker("", selection: $model.settings.spellingLanguage) {
                                Text("Rozpoznať jazyk").tag("auto")
                                ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                    }
                    Text(model.settings.messageFormat == .plain
                         ? "Odošle sa len text: Markdown sa prevedie na čitateľný text bez formátovania."
                         : "Odošle sa HTML vytvorené z Markdownu a k nemu textová verzia.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                SettingsCard("Odpoveď a preposlanie") {
                    SettingsRow("Vložiť podpis pri") {
                        Picker("", selection: $model.settings.signaturePlacement) {
                            ForEach(SignaturePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                    Text("Predvolený odosielateľ sa nastavuje v časti Účty.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func signature(for accountID: String) -> Binding<String> {
        Binding(
            get: { model.settings.signatures[accountID] ?? "" },
            set: { model.settings.signatures[accountID] = $0 }
        )
    }

    /// Languages the system spell checker has, Slovak/Czech/English first.
    static let languages: [(code: String, name: String)] = {
        let available = NSSpellChecker.shared.availableLanguages
        let preferred = ["sk", "cs", "en", "de", "hu", "pl"]
        let codes = preferred.filter(available.contains) + available.filter { !preferred.contains($0) && !$0.contains("_") }
        let locale = Locale(identifier: "sk_SK")
        return codes.map { ($0, locale.localizedString(forIdentifier: $0)?.capitalized ?? $0) }
    }()
}

/// A signature with a small formatting toolbar, edited with the live Markdown editor.
private struct SignatureEditor: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @Binding var text: String
    @State private var editor = MarkdownEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AccountBadge(account: account, size: 22)
                Text(model.accountTitle(account)).font(.system(size: 13, weight: .medium)).help(account.email)
                Spacer()
                HStack(spacing: 2) {
                    FormatButton(symbol: "bold", help: "Tučné") { editor.toggleWrap("**") }
                    FormatButton(symbol: "italic", help: "Kurzíva") { editor.toggleWrap("*") }
                    FormatButton(symbol: "link", help: "Odkaz") { editor.insertLink() }
                    FormatButton(symbol: "list.bullet", help: "Zoznam") { editor.toggleLinePrefix(.bullet) }
                    FormatButton(symbol: "list.number", help: "Číslovaný zoznam") { editor.toggleLinePrefix(.numbered) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            MarkdownEditor(text: $text, controller: editor)
                .frame(height: 90)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Pridajte svoj podpis…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 19)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}
