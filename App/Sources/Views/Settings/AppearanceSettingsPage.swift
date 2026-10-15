import AppKit
import MailmuleKit
import SwiftUI

/// Themes like in Pathfinder, the message list layout and the sidebar background.
struct AppearanceSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var theme = ThemeStore.shared

    private static let accents: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .gray]

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .appearance) {
            SettingsCard {
                SettingsRows {
                    SettingsRow("Motív aplikácie", detail: theme.preset.appearance.map {
                        "Téma \(theme.preset.name) je \($0 == .dark ? "tmavá" : "svetlá")."
                    } ?? "Svetlý, tmavý alebo podľa nastavenia macOS.") {
                        Picker("", selection: $theme.appearance) {
                            Text("Svetlý").tag(AppearanceMode.light)
                            Text("Tmavý").tag(AppearanceMode.dark)
                            Text("Podľa systému").tag(AppearanceMode.system)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(theme.preset.appearance != nil)
                    }
                    SettingsRow("Akcentová farba", detail: "Zvýraznenie výberu, tlačidiel a neprečítaných správ.") {
                        HStack(spacing: 8) {
                            Button { theme.customAccent = nil } label: {
                                Text("Téma").font(.system(size: 11))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.primary.opacity(theme.customAccent == nil ? 0.15 : 0.05), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            ForEach(Self.accents, id: \.self) { color in
                                Button { theme.customAccent = color } label: {
                                    Circle().fill(color).frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: isAccent(color) ? 2.5 : 0))
                                        .overlay(Circle().strokeBorder(color, lineWidth: isAccent(color) ? 1.5 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                            }
                            ColorPicker("", selection: Binding(get: { theme.accent }, set: { theme.customAccent = $0 }),
                                        supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 44)
                        }
                        .fixedSize()
                    }
                }
            }

            SettingsCard("Téma", subtitle: "Farby bočného panela, zoznamu a líšt. Tmavé a svetlé palety si vynútia svoj režim.") {
                ForEach([("Základné", nil), ("Tmavé", AppearanceMode.dark), ("Svetlé", AppearanceMode.light)], id: \.0) { title, mode in
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 12) {
                        ForEach(ThemePreset.all.filter { $0.appearance == mode }) { preset in
                            ThemeSwatch(preset: preset, isSelected: preset.id == theme.presetID)
                                .onTapGesture { theme.presetID = preset.id }
                        }
                    }
                }
            }

            SettingsCard("Rozloženie", subtitle: "Ako vyzerá hlavné okno a zoznam správ.") {
                SettingsRows {
                    SettingsToggle("Kompaktný zoznam správ", detail: "Jeden riadok na vlákno, viac správ na obrazovke.",
                                   isOn: Binding(get: { model.listView.density == .compact },
                                                 set: { model.listView.density = $0 ? .compact : .comfortable }))
                    SettingsToggle("Zobraziť ukážku správy", detail: "Začiatok textu pod predmetom.", isOn: $model.settings.showPreview)
                    SettingsToggle("Veľké avatary", detail: "Väčšie iniciály odosielateľa v zozname.", isOn: $model.settings.largeAvatars)
                    SettingsRow("Predvolené rozloženie", detail: "Pri dvoch stĺpcoch je bočný panel skrytý; zobrazíte ho tlačidlom v lište.") {
                        Picker("", selection: $model.settings.threeColumns) {
                            Text("2 stĺpce").tag(false)
                            Text("3 stĺpce").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsCard("Pozadie bočného panela", subtitle: "Obrázok za bočným panelom; text sa prispôsobí jeho jasu.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 10) {
                    SidebarBackgroundTile(title: "Téma", isSelected: theme.sidebarBackground == .theme) {
                        theme.sidebarBackground = .theme
                    }
                    ForEach(SidebarBackground.builtins, id: \.self) { number in
                        SidebarBackgroundTile(url: SidebarBackground.builtinURL(number),
                                              isSelected: theme.sidebarBackground == .builtin(number)) {
                            theme.sidebarBackground = .builtin(number)
                        }
                    }
                    if case .custom(let url) = theme.sidebarBackground {
                        SidebarBackgroundTile(url: url, isSelected: true) {}
                    }
                    SidebarBackgroundTile(title: "Vlastný…", symbol: "plus", isSelected: false) { chooseSidebarImage() }
                }
                SettingsRows {
                    if theme.sidebarImage != nil {
                        SettingsRow("Intenzita prekrytia", detail: "Ako veľmi sa obrázok stmaví alebo zosvetlí pod textom.") {
                            HStack {
                                Slider(value: $theme.sidebarScrim, in: 0...0.8).frame(width: 220)
                                Text("\(Int(theme.sidebarScrim / 0.8 * 100)) %")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        SettingsRow("Kontrast textu") {
                            Picker("", selection: $theme.sidebarText) {
                                ForEach(SidebarTextContrast.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                    }
                    SettingsToggle("Hory a heslo v bočnom paneli", detail: theme.sidebarIsDark ? nil : "Len pri tmavom bočnom paneli.",
                                   isOn: $theme.sidebarDecoration)
                        .disabled(!theme.sidebarIsDark)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                SettingsCard("Zoznam správ") {
                    SettingsRows {
                        SettingsRow("Riadkovanie") {
                            Picker("", selection: $model.settings.rowSpacing) {
                                ForEach(RowSpacing.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        SettingsRow("Dĺžka ukážky") {
                            Picker("", selection: $model.settings.previewLines) {
                                Text("1 riadok").tag(1)
                                Text("2 riadky").tag(2)
                                Text("3 riadky").tag(3)
                            }
                            .labelsHidden()
                            .frame(width: 250)
                            .disabled(!model.settings.showPreview)
                        }
                    }
                }
                SettingsCard("Náhľad", subtitle: "Takto bude vyzerať zoznam správ.") {
                    ListPreview()
                }
            }

            SettingsCard("Obrázok na pozadí", subtitle: "Obrázok za zoznamom a obsahom správy.") {
                SettingsRows {
                    SettingsRow("Obrázok") {
                        HStack {
                            Text(theme.backgroundImage?.lastPathComponent ?? "Žiadny")
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Vybrať…") { chooseImage() }
                            if theme.backgroundImage != nil {
                                Button("Odstrániť") { theme.backgroundImage = nil }
                            }
                        }
                    }
                    if theme.backgroundImage != nil {
                        SettingsRow("Priehľadnosť") {
                            Slider(value: $theme.backgroundOpacity, in: 0.05...1).frame(width: 220)
                        }
                    }
                }
            }
        }
    }

    private func isAccent(_ color: Color) -> Bool {
        theme.customAccent.map { $0.hex == color.hex } ?? false
    }

    private func chooseSidebarImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Vyber obrázok na pozadie bočného panela (najlepšie na výšku)."
        if panel.runModal() == .OK, let url = panel.url { theme.sidebarBackground = .custom(url) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { theme.backgroundImage = url }
    }
}

/// Three sample threads drawn with the real row views and current settings.
private struct ListPreview: View {
    @Environment(AppModel.self) private var model

    private var samples: [ThreadSummary] {
        let account = model.settings.accounts.first?.id ?? ""
        let now = Date()
        return [
            ThreadSummary(id: "preview-1", accountID: account, subject: "Re: Stretnutie v pondelok", participants: ["Jana Múčková"],
                          date: now.addingTimeInterval(-1800), messageCount: 2, unreadCount: 1,
                          snippet: "Ahoj, posielam ti podklady k nášmu stretnutiu. Pozri sa prosím hlavne na druhú stranu.",
                          latestSender: "Jana Múčková"),
            ThreadSummary(id: "preview-2", accountID: account, subject: "Plán na Q2", participants: ["Tomáš Bartoš"],
                          date: now.addingTimeInterval(-86_400), messageCount: 1, unreadCount: 0,
                          snippet: "Tu je finálna verzia dokumentu, daj mi vedieť, čo si o ňom myslíš.",
                          latestSender: "Tomáš Bartoš", flagged: true),
            ThreadSummary(id: "preview-3", accountID: account, subject: "Fotky z konferencie", participants: ["Eva Kováčová"],
                          date: now.addingTimeInterval(-86_400 * 5), messageCount: 1, unreadCount: 0,
                          snippet: "Prikladám niekoľko fotiek z minulého týždňa.", latestSender: "Eva Kováčová", hasAttachments: true),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(samples.enumerated()), id: \.element.id) { offset, thread in
                if offset > 0 { Divider() }
                Group {
                    if model.listView.density == .compact {
                        CompactThreadRow(thread: thread)
                    } else {
                        ThreadRow(thread: thread)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .allowsHitTesting(false)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}
