import EventKit
import MailmuleKit
import SwiftUI

extension AppModel {
    /// Your answer to an invitation: what you chose in Mailmule, else what the invite says about you.
    func inviteStatus(_ invite: CalendarInvite) -> CalendarInvite.Status? {
        settings.inviteResponses[invite.uid].flatMap(CalendarInvite.Status.init(rawValue:))
            ?? invite.status(of: settings.accounts.map(\.email))
    }

    /// Sends the answer to the organizer (an iCalendar REPLY their calendar understands) and,
    /// for yes or maybe, adds the meeting to Calendar.
    func respond(to invite: CalendarInvite, in message: StoredMessage, with status: CalendarInvite.Status) async {
        guard let organizer = invite.organizer, let account = account(message.accountID),
              let service = service(for: message.accountID) else { return }
        // Answer as the address the invitation was sent to.
        let invited = invite.attendees.first { attendee in settings.accounts.contains { $0.email.caseInsensitiveCompare(attendee.address) == .orderedSame } }
        let me = EmailAddress(name: account.name, address: invited?.address ?? account.email)
        let (verb, prefix) = switch status {
        case .accepted: ("prijal(a)", "Prijaté")
        case .tentative: ("možno príde – predbežne prijal(a)", "Predbežne prijaté")
        case .declined: ("odmietol(a)", "Odmietnuté")
        case .needsAction: ("", "")
        }
        var draft = Draft(from: me, to: [organizer], subject: "\(prefix): \(invite.summary)",
                          markdown: "\(account.name) \(verb) pozvánku „\(invite.summary)“.")
        draft.calendarReply = invite.reply(status, from: me)
        do {
            _ = try await service.send(draft)
            settings.inviteResponses[invite.uid] = status.rawValue
            showToast("\(prefix): \(invite.summary)")
            log("pozvánka \(invite.uid): \(status.rawValue)")
            if status != .declined && settings.addAcceptedToCalendar { await addToCalendar(invite) }
        } catch {
            errorMessage = "Odpoveď na pozvánku sa nepodarilo odoslať: \(error.localizedDescription)"
        }
    }

    /// Adds the event to the default calendar (write-only access: Mailmule cannot read your calendar).
    func addToCalendar(_ invite: CalendarInvite) async {
        guard !settings.calendarAdded.contains(invite.uid), let start = invite.start else { return }
        let store = CalendarLink.store
        do {
            let allowed = CalendarLink.hasFullAccess ? true : try await store.requestWriteOnlyAccessToEvents()
            guard allowed else {
                errorMessage = "Mailmule nemá prístup ku Kalendáru. Povoľte ho v Systémových nastaveniach → Súkromie → Kalendáre."
                return
            }
            let event = EKEvent(eventStore: store)
            event.title = invite.summary.isEmpty ? "Stretnutie" : invite.summary
            event.startDate = start
            event.endDate = invite.end ?? start.addingTimeInterval(invite.isAllDay ? 86_400 : 3_600)
            event.isAllDay = invite.isAllDay
            event.location = invite.location
            event.url = invite.conferenceURL
            event.notes = invite.details
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            settings.calendarAdded.append(invite.uid)
            showToast("Pridané do Kalendára")
        } catch {
            errorMessage = "Udalosť sa nepodarilo pridať do Kalendára: \(error.localizedDescription)"
        }
    }
}

/// The invitation above a message: what, when, where, and Prijať / Možno / Odmietnuť.
struct InviteCard: View {
    @Environment(AppModel.self) private var model
    let invite: CalendarInvite
    let message: StoredMessage
    @State private var busy = false

    var body: some View {
        let status = model.inviteStatus(invite)
        let isOrganizer = model.isOwn(invite.organizer)
        HStack(alignment: .top, spacing: 14) {
            dateBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(invite.summary.isEmpty ? "Stretnutie" : invite.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .strikethrough(invite.isCancelled)
                Text(when).font(.system(size: 12.5)).foregroundStyle(.secondary)
                if let location = invite.location, location != invite.conferenceURL?.absoluteString {
                    Label(location, systemImage: "mappin.and.ellipse").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let organizer = invite.organizer, !isOrganizer {
                    Label("Organizátor: \(organizerName(organizer))", systemImage: "person").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if isPast && !invite.isCancelled {
                    Label("Stretnutie už prebehlo", systemImage: "clock.badge.checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if invite.isCancelled {
                    Label("Stretnutie bolo zrušené", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                } else if invite.method == .reply {
                    Label(replySummary, systemImage: "envelope.badge").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if invite.method == .request && !invite.isCancelled && !isOrganizer && invite.organizer != nil && !isPast {
                        answer("Prijať", .accepted, status, tint: .green)
                        answer("Možno", .tentative, status, tint: .orange)
                        answer("Odmietnuť", .declined, status, tint: .red)
                    }
                    if !invite.isCancelled && invite.method != .reply && !isPast {
                        if model.settings.calendarAdded.contains(invite.uid) {
                            Label("V Kalendári", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if invite.method != .request || status != nil && status != .needsAction {
                            Button { Task { await model.addToCalendar(invite) } } label: {
                                Label("Pridať do Kalendára", systemImage: "calendar.badge.plus")
                            }
                        }
                    }
                    if let url = invite.conferenceURL, !invite.isCancelled, !isPast {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Pripojiť sa", systemImage: "video") }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.themeAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.themeAccent.opacity(0.2)))
    }

    private func answer(_ title: String, _ value: CalendarInvite.Status, _ current: CalendarInvite.Status?, tint: Color) -> some View {
        let chosen = current == value
        return Button {
            busy = true
            Task {
                await model.respond(to: invite, in: message, with: value)
                busy = false
            }
        } label: {
            Label(title, systemImage: chosen ? "checkmark.circle.fill" : "circle")
        }
        .tint(chosen ? tint : nil)
        .buttonStyle(.bordered)
        .disabled(busy)
        .help(chosen ? "Vaša odpoveď" : "Odpovedať organizátorovi: \(title.lowercased())")
    }

    private var isPast: Bool {
        (invite.end ?? invite.start).map { $0 < Date() } ?? false
    }

    /// The organizer's name; invitations often carry only the address, while the mail's sender has the name.
    private func organizerName(_ organizer: EmailAddress) -> String {
        if let name = organizer.name, !name.contains("@") { return name }
        if let from = message.from, from.address.caseInsensitiveCompare(organizer.address) == .orderedSame, let name = from.name {
            return name
        }
        return organizer.address
    }

    private var dateBadge: some View {
        VStack(spacing: 0) {
            Text(invite.start.map { $0.formatted(.dateTime.month(.abbreviated)) }?.uppercased() ?? "")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Color.red)
            Text(invite.start.map { $0.formatted(.dateTime.day()) } ?? "?")
                .font(.system(size: 22, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 48, height: 52)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var when: String {
        guard let start = invite.start else { return "" }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if invite.isAllDay {
            if let end = invite.end, end.timeIntervalSince(start) > 86_400 {
                return "\(day) – \(end.addingTimeInterval(-1).formatted(.dateTime.day().month(.wide))) · celý deň"
            }
            return "\(day) · celý deň"
        }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = invite.end else { return "\(day) · \(from)" }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(day) · \(from) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(day) \(from) – \(end.formatted(date: .abbreviated, time: .shortened))"
    }

    private var replySummary: String {
        guard let attendee = invite.attendees.first else { return "Odpoveď na pozvánku" }
        let who = attendee.name ?? attendee.address
        return switch attendee.status {
        case .accepted?: "\(who) prijal(a)"
        case .tentative?: "\(who) možno príde"
        case .declined?: "\(who) odmietol(a)"
        default: "Odpoveď od \(who)"
        }
    }
}
