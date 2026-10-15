import AppKit
import MailmuleKit
import SwiftUI
import UserNotifications

struct NotificationSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .notifications) {
            SettingsCard(tint: status == .denied ? .orange : nil) {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 20))
                        .foregroundStyle(status == .authorized || status == .provisional ? Color.green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.system(size: 13, weight: .medium))
                        Text(statusDetail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if status == .denied {
                        Button("Otvoriť nastavenia macOS…") { Notifier.openSystemSettings() }
                    } else if status == .notDetermined {
                        Button("Povoliť upozornenia") { Task { status = await Notifier.ensureAuthorization() } }
                    }
                    Button("Poslať skúšobné upozornenie") {
                        Task {
                            status = await Notifier.ensureAuthorization()
                            if status == .denied { Notifier.openSystemSettings() } else { Notifier.sendTest(settings: model.settings) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            SettingsCard("Upozornenia na nové správy", subtitle: "Upozorňuje len na novú poštu v Doručenej, nie na históriu sťahovanú na pozadí.") {
                SettingsRows {
                    SettingsToggle("Zobrazovať bannery", isOn: $model.settings.notifyBanners)
                    SettingsToggle("Prehrať zvuk", isOn: $model.settings.notifySound)
                    SettingsToggle("Počet neprečítaných v Docku", isOn: $model.settings.dockBadge)
                        .onChange(of: model.settings.dockBadge) { model.refreshDockBadge() }
                    SettingsToggle("Ukážka správy v upozornení", detail: "Prvé riadky textu pod predmetom.",
                                   isOn: $model.settings.notifyPreview)
                        .disabled(!model.settings.notifyBanners)
                }
            }

            SettingsCard("Priorita upozornení", subtitle: "Ktoré správy majú vyvolať upozornenie.", accessory: {
                Picker("", selection: $model.settings.notifyOnlyVIP) {
                    Text("Všetky správy").tag(false)
                    Text("Len VIP").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }) {
                Text("VIP odosielatelia").font(.system(size: 13))
                Text("Adresa alebo celá doména (@firma.sk). Pri voľbe „Len VIP“ upozornia len ich správy.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                AddressChips(entries: $model.settings.vipSenders)
            }

            SettingsCard("Tichý režim", subtitle: "V tomto čase Mailmule neupozorňuje; pošta sa normálne sťahuje.", accessory: {
                Toggle("", isOn: $model.settings.quietHours).toggleStyle(.switch).labelsHidden()
            }) {
                SettingsRow("Čas tichého režimu") {
                    HStack {
                        Text("Od").foregroundStyle(.secondary)
                        TimePicker(minutes: $model.settings.quietFrom)
                        Text("do").foregroundStyle(.secondary)
                        TimePicker(minutes: $model.settings.quietTo)
                    }
                    .disabled(!model.settings.quietHours)
                }
            }

            SettingsCard("Podľa účtu", subtitle: "Upozornenia a zvuk pre každý účet zvlášť.") {
                SettingsRows {
                    ForEach(model.settings.accounts) { account in
                        HStack(spacing: 12) {
                            AccountBadge(account: account, size: 26)
                            Text(model.accountTitle(account)).font(.system(size: 13)).help(account.email)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !model.settings.mutedAccounts.contains(account.id) },
                                set: { on in
                                    model.settings.mutedAccounts.removeAll { $0 == account.id }
                                    if !on { model.settings.mutedAccounts.append(account.id) }
                                }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Text("Zvuk").foregroundStyle(.secondary).font(.system(size: 12))
                            Picker("", selection: sound(for: account.id)) {
                                Text("Predvolený").tag("")
                                Text("Žiadny").tag("none")
                                Divider()
                                ForEach(Notifier.systemSounds, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            .onChange(of: model.settings.accountSounds[account.id]) { _, name in
                                if let name, !name.isEmpty, name != "none" { NSSound(named: name)?.play() }
                            }
                        }
                    }
                }
            }

            SettingsCard(tint: .gray) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.circle").font(.system(size: 20)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Režimy sústredenia").font(.system(size: 13, weight: .medium))
                        Text("Upozornenia Mailmule rešpektujú režim sústredenia v macOS, aj zdieľanie obrazovky.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Otvoriť nastavenia macOS…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                    }
                }
            }
        }
        .task { status = await Notifier.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await Notifier.authorizationStatus() }
        }
    }

    private var statusSymbol: String {
        switch status {
        case .authorized, .provisional: "checkmark.circle.fill"
        case .denied: "bell.slash.fill"
        default: "questionmark.circle"
        }
    }

    private var statusTitle: String {
        switch status {
        case .authorized, .provisional: "Upozornenia sú v macOS povolené"
        case .denied: "Upozornenia sú v macOS zakázané"
        case .notDetermined: "Upozornenia ešte neboli povolené"
        default: "Zisťujem stav upozornení…"
        }
    }

    private var statusDetail: String {
        switch status {
        case .denied: "Zapnite ich v Systémových nastaveniach → Upozornenia → Mailmule."
        case .notDetermined: "macOS sa opýta na povolenie."
        default: "Upozorní na novú poštu v Doručenej počas behu Mailmule. Na poštu prijatú, keď bol Mailmule zatvorený, neupozorňuje."
        }
    }

    private func sound(for accountID: String) -> Binding<String> {
        Binding(get: { model.settings.accountSounds[accountID] ?? "" },
                set: { model.settings.accountSounds[accountID] = $0 })
    }
}

/// Hour and minute picker over "minutes after midnight".
private struct TimePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .frame(width: 250)
    }
}
