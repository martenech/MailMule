import MailmuleKit
import SwiftUI

/// Preset snooze times, like Superhuman's.
struct SnoozeOption: Identifiable {
    let id: String
    let title: String
    let date: Date

    /// The options that make sense right now (no "tonight" late in the evening).
    static func presets(now: Date = Date()) -> [SnoozeOption] {
        let calendar = Calendar.current
        func at(_ hour: Int, daysFromNow: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysFromNow, to: now)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        var options: [SnoozeOption] = []
        let hour = calendar.component(.hour, from: now)
        if hour < 20 {
            let later = calendar.date(byAdding: .hour, value: 3, to: now)!
            let rounded = calendar.date(bySetting: .minute, value: 0, of: later) ?? later
            options.append(SnoozeOption(id: "later", title: "Neskôr dnes", date: rounded))
        }
        if hour < 17 {
            options.append(SnoozeOption(id: "evening", title: "Dnes večer", date: at(18, daysFromNow: 0)))
        }
        options.append(SnoozeOption(id: "tomorrow", title: "Zajtra ráno", date: at(8, daysFromNow: 1)))
        options.append(SnoozeOption(id: "tomorrowAfternoon", title: "Zajtra popoludní", date: at(13, daysFromNow: 1)))
        // Weekday: 1 = Sunday … 7 = Saturday.
        let weekday = calendar.component(.weekday, from: now)
        // Next Saturday 9:00 (today if it is Saturday morning).
        var toSaturday = (7 - weekday) % 7
        if toSaturday == 0 && hour >= 9 { toSaturday = 7 }
        options.append(SnoozeOption(id: "weekend", title: weekday == 7 || weekday == 1 ? "Budúci víkend" : "Tento víkend",
                                    date: at(9, daysFromNow: toSaturday)))
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        options.append(SnoozeOption(id: "nextWeek", title: "Budúci týždeň", date: at(8, daysFromNow: toMonday)))
        return options
    }

    /// "dnes 18:00", "zajtra 8:00", "so 18. 10. 9:00".
    static func describe(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "dnes \(time)" }
        if calendar.isDateInTomorrow(date) { return "zajtra \(time)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "EE d. M."
        return "\(formatter.string(from: date)) \(time)"
    }
}

/// "Odložiť do…" (`h`): presets or a custom date and time.
struct SnoozePicker: View {
    @Environment(AppModel.self) private var model
    let threadIDs: [String]
    @State private var selection = 0
    @State private var custom = false
    @State private var customDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    var body: some View {
        let options = SnoozeOption.presets()
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                Label(threadIDs.count > 1 ? "Odložiť \(threadIDs.count) vlákien do…" : "Odložiť do…", systemImage: "clock")
                    .font(.title3)
                    .padding(14)
                Divider()
                if custom {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        HStack {
                            Button("Späť") { custom = false }
                            Spacer()
                            Button("Odložiť do \(SnoozeOption.describe(customDate))") { snooze(until: customDate) }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                            row(option.title, detail: SnoozeOption.describe(option.date), selected: offset == selection) {
                                snooze(until: option.date)
                            }
                        }
                        row("Vlastný čas…", detail: "", selected: selection == options.count) { custom = true }
                    }
                    .padding(6)
                }
            }
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(.top, 80)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { selection = min(selection + 1, options.count); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.return) {
                if custom { return .ignored }
                if selection < options.count { snooze(until: options[selection].date) } else { custom = true }
                return .handled
            }
        }
    }

    private func row(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.themeAccent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func snooze(until date: Date) {
        close()
        model.snooze(threadIDs, until: date)
    }

    private func close() {
        model.snoozePickerThreadIDs = nil
    }
}
