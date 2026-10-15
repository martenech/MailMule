import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDefaults = false
    @State private var confirmSignOut = false
    @State private var backingUp = false

    var body: some View {
        SettingsPage(category: .advanced) {
            SettingsCard("Servis a diagnostika", subtitle: "Pri riešení problémov.") {
                SettingsRows {
                    SettingsRow("Záznam aplikácie", detail: "Synchronizácia, chyby a odoslané správy (bez obsahu).") {
                        Button("Zobraziť záznam…") { model.openLog() }
                    }
                    SettingsRow("Exportovať diagnostiku", detail: "Záznam, verzie a stav účtov v jednom súbore; bez hesiel a obsahu pošty.") {
                        Button("Exportovať…") {
                            if let url = Self.savePanel(name: "Mailmule-diagnostika.txt", type: .plainText) {
                                Task { await model.exportDiagnostics(to: url) }
                            }
                        }
                    }
                }
            }

            SettingsCard("Import / Export", subtitle: "Prenesie nastavenia na iný Mac. Heslá ostávajú v kľúčenke a neexportujú sa.") {
                SettingsRows {
                    SettingsRow("Exportovať nastavenia", detail: "Účty, podpisy, pravidlá zobrazenia, témy.") {
                        Button("Exportovať…") {
                            if let url = Self.savePanel(name: "Mailmule-nastavenia.json", type: .json) { model.exportSettings(to: url) }
                        }
                    }
                    SettingsRow("Importovať nastavenia", detail: "Nahradí súčasné nastavenia; heslá doplníte pri účtoch.") {
                        Button("Importovať…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.json]
                            if panel.runModal() == .OK, let url = panel.url { Task { await model.importSettings(from: url) } }
                        }
                    }
                    SettingsRow("Zálohovať poštu", detail: "Celý mail vault (správy, poznámky, koncepty) do jedného .zip súboru.") {
                        Button(backingUp ? "Zálohujem…" : "Zálohovať…") {
                            let name = "Mailmule-zaloha-\(Date().formatted(.iso8601.year().month().day())).zip"
                            if let url = Self.savePanel(name: name, type: .zip) {
                                backingUp = true
                                Task {
                                    await model.backupVault(to: url)
                                    backingUp = false
                                }
                            }
                        }
                        .disabled(backingUp)
                    }
                }
            }

            SettingsCard("Reset", subtitle: "Pošta v Macu ani na serveri sa nezmaže.", tint: .red) {
                SettingsRows {
                    SettingsRow("Obnoviť rozloženie okien", detail: "Veľkosť okna a šírky stĺpcov sa vrátia pri ďalšom spustení.") {
                        Button("Obnoviť rozloženie") { model.resetWindowLayout() }
                    }
                    SettingsRow("Obnoviť predvolené nastavenia", detail: "Všetky voľby a téma; účty a podpisy ostanú.") {
                        Button("Obnoviť nastavenia…") { confirmDefaults = true }
                    }
                    SettingsRow("Odhlásiť všetky účty", detail: "Zmaže heslá z kľúčenky a zastaví synchronizáciu. Účty a stiahnutá pošta ostanú.") {
                        Button("Odhlásiť všetky účty…", role: .destructive) { confirmSignOut = true }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .confirmationDialog("Obnoviť predvolené nastavenia?", isPresented: $confirmDefaults) {
            Button("Obnoviť", role: .destructive) { model.resetSettingsToDefaults() }
        } message: {
            Text("Vráti všetky voľby, tému a zobrazenie zoznamu na predvolené. Účty, heslá, podpisy a štítky ostanú.")
        }
        .confirmationDialog("Odhlásiť všetky účty?", isPresented: $confirmSignOut) {
            Button("Odhlásiť", role: .destructive) { Task { await model.signOutAllAccounts() } }
        } message: {
            Text("Heslá sa zmažú z kľúčenky a Mailmule prestane sťahovať a odosielať poštu. Prihlásite sa znova zadaním hesla v časti Účty → … → Upraviť.")
        }
    }

    static func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
