import SwiftUI

struct PrivacySettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .privacy) {
            SettingsCard("Ochrana súkromia", subtitle: "Obrázky z internetu prezradia odosielateľovi, že ste mail otvorili, kedy a odkiaľ.") {
                SettingsRows {
                    SettingsToggle("Načítavať obrázky až po potvrdení",
                                   detail: "Nad mailom s obrázkami sa zobrazí tlačidlo „Načítať obrázky“. Obrázky vložené priamo v maile sa zobrazujú vždy.",
                                   symbol: "photo", isOn: Binding(get: { !model.settings.loadRemoteImages },
                                                                  set: { model.settings.loadRemoteImages = !$0 }))
                    SettingsToggle("Blokovať sledovacie pixely",
                                   detail: "Keď sa obrázky načítajú, vynechá neviditeľné obrázky 1×1 px a známe sledovacie adresy.",
                                   symbol: "eye.slash", isOn: $model.settings.blockTrackers)
                    SettingsToggle("Logá firiem pri odosielateľoch",
                                   detail: "Ikona z webu firmy (alebo cez DuckDuckGo, ktorý neprezradí, kto sa pýta), raz pre každú doménu. Fotky z Kontaktov sa zobrazujú vždy.",
                                   symbol: "building.2", isOn: $model.settings.senderLogos)
                        .onChange(of: model.settings.senderLogos) { if !model.settings.senderLogos { AvatarStore.shared.clearCache() } }
                    SettingsRow("Skripty v správach", detail: "JavaScript v e-mailoch sa nikdy nespúšťa.", symbol: "curlybraces") {
                        Label("Vždy vypnuté", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                }
            }

            SettingsCard("Bezpečnosť správ", subtitle: "Ochrana pred podvodmi, ktoré sa vydávajú za niekoho iného.") {
                SettingsToggle("Varovať pri podozrivých odosielateľoch",
                               detail: "Upozorní, keď meno odosielateľa obsahuje inú adresu, než z ktorej mail prišiel, alebo keď firemný mail chce odpoveď na súkromnú schránku (napr. Gmail).",
                               symbol: "exclamationmark.shield", isOn: $model.settings.warnSuspicious)
            }

            SettingsCard("Výnimky", subtitle: "Od týchto odosielateľov a domén sa obrázky načítajú automaticky. Pridáte ich aj tlačidlom „Vždy od …“ nad mailom.") {
                AddressChips(entries: $model.settings.trustedImageSenders, placeholder: "adresa, @domena.sk alebo *.domena.sk")
            }
        }
    }
}
