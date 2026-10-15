import EventKit
import MailmuleKit
import SwiftUI

struct CalendarSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var status = CalendarLink.status
    @State private var calendars: [EKCalendar] = CalendarLink.calendars

    private var connected: Bool { model.settings.calendarConnected && status == .fullAccess }

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .calendar) {
            SettingsCard(tint: status == .denied ? .orange : nil) {
                HStack(spacing: 12) {
                    Image(systemName: connected ? "checkmark.circle.fill" : "calendar.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(connected ? Color.green : status == .denied ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if connected {
                        Button("Odpojiť") { model.settings.calendarConnected = false; model.calendarRevision += 1 }
                    } else if status == .denied || status == .restricted || status == .writeOnly {
                        Button("Otvoriť nastavenia macOS…") { CalendarLink.openPrivacySettings() }
                    } else {
                        Button("Pripojiť Kalendár") { connect() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if connected {
                SettingsCard("Zobrazené kalendáre", subtitle: "Udalosti z týchto kalendárov uvidíte v Prehľade (dnes a zajtra).") {
                    SettingsRows {
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: Binding(
                                get: { !model.settings.calendarHidden.contains(calendar.calendarIdentifier) },
                                set: { on in
                                    model.settings.calendarHidden.removeAll { $0 == calendar.calendarIdentifier }
                                    if !on { model.settings.calendarHidden.append(calendar.calendarIdentifier) }
                                    model.calendarRevision += 1
                                })) {
                                HStack(spacing: 8) {
                                    Circle().fill(calendar.cgColor.map { Color(cgColor: $0) } ?? .gray).frame(width: 10, height: 10)
                                    Text(calendar.title)
                                    Text(calendar.source.title).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                        }
                        if calendars.isEmpty {
                            Text("V Kalendári nie sú žiadne kalendáre.").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsCard("Pozvánky v pošte", subtitle: "Stretnutia z pozvánok (.ics) sa v Prehľade zobrazia aj bez pripojeného Kalendára.") {
                SettingsRows {
                    SettingsToggle("Prijaté pozvánky pridávať do Kalendára",
                                   detail: "Po kliknutí na Prijať alebo Možno sa stretnutie zapíše do predvoleného kalendára.",
                                   isOn: $model.settings.addAcceptedToCalendar)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in refresh() }
        .onAppear { refresh() }
    }

    private var title: String {
        if connected { return "Kalendár je pripojený" }
        switch status {
        case .denied, .restricted: return "Mailmule nemá prístup ku Kalendáru"
        case .writeOnly: return "Mailmule smie do Kalendára len zapisovať"
        default: return "Kalendár nie je pripojený"
        }
    }

    private var detail: String {
        if connected { return "Prehľad ukazuje udalosti z Kalendára v Macu – aj z Google, iCloud či Exchange kalendárov pridaných v Nastaveniach systému → Internetové účty." }
        switch status {
        case .denied, .restricted, .writeOnly:
            return "Povoľte Mailmule „Úplný prístup“ v Nastaveniach systému → Súkromie a bezpečnosť → Kalendáre."
        default:
            return "Udalosti z Kalendára v Macu (Google, iCloud, Exchange…) sa zobrazia v Prehľade. Kalendár neopúšťa váš Mac."
        }
    }

    private func connect() {
        Task {
            let granted = await CalendarLink.requestAccess()
            model.settings.calendarConnected = granted
            refresh()
            model.calendarRevision += 1
        }
    }

    private func refresh() {
        status = CalendarLink.status
        calendars = CalendarLink.calendars
    }
}
