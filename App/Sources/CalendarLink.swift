import AppKit
import EventKit
import MailmuleKit
import SwiftUI

/// An event on Prehľad: from the Mac's Calendar, from an invitation in mail, or both.
struct HomeEvent: Identifiable, Hashable {
    let id: String
    var title: String
    var start: Date
    var end: Date?
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String?
    var color: Color?
    /// The mail with the invitation.
    var threadID: String?
    /// EventKit identifier, to show the event in Calendar.
    var calendarItemID: String?
    var joinURL: URL?
}

/// Reading the Mac's Calendar (iCloud, Google, Exchange… whatever is added in macOS) for Prehľad.
@MainActor
enum CalendarLink {
    static let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var hasFullAccess: Bool { status == .fullAccess }

    /// Asks for full access; false when refused (then only System Settings can change it).
    static func requestAccess() async -> Bool {
        if hasFullAccess { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { store.reset() }
        return granted
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    static var calendars: [EKCalendar] {
        guard hasFullAccess else { return [] }
        return store.calendars(for: .event).sorted {
            ($0.source.title.lowercased(), $0.title.lowercased()) < ($1.source.title.lowercased(), $1.title.lowercased())
        }
    }

    static func events(from start: Date, to end: Date, hidden: [String]) -> [HomeEvent] {
        guard hasFullAccess else { return [] }
        let shown = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled && !declined($0) }
            .map { event in
                HomeEvent(id: "ek:\(event.calendarItemIdentifier):\(event.startDate.timeIntervalSince1970)",
                          title: event.title ?? "",
                          start: event.startDate,
                          end: event.endDate,
                          isAllDay: event.isAllDay,
                          location: event.location?.nonEmpty,
                          calendarTitle: event.calendar.title,
                          color: event.calendar.cgColor.map { Color(cgColor: $0) },
                          calendarItemID: event.calendarItemIdentifier,
                          joinURL: joinURL(event.url, event.location, event.notes))
            }
    }

    /// Calendar events plus invitations from mail; an invitation already in Calendar is shown once,
    /// keeping the link to its mail.
    static func merge(invites: [StoredEvent], calendar: [HomeEvent]) -> [HomeEvent] {
        var result = calendar
        for invite in invites {
            let title = invite.summary.lowercased()
            if let index = result.firstIndex(where: { abs($0.start.timeIntervalSince(invite.start)) < 60 && $0.title.lowercased() == title }) {
                result[index].threadID = invite.threadID
                continue
            }
            result.append(HomeEvent(id: "mail:\(invite.uid)", title: invite.summary, start: invite.start, end: invite.end,
                                    isAllDay: invite.isAllDay, location: invite.location, threadID: invite.threadID,
                                    joinURL: joinURL(nil, invite.location, nil)))
        }
        let calendar = Calendar.current
        return result.sorted {
            (calendar.startOfDay(for: $0.start), $0.isAllDay ? 0 : 1, $0.start) < (calendar.startOfDay(for: $1.start), $1.isAllDay ? 0 : 1, $1.start)
        }
    }

    /// Shows the event in the Calendar app.
    static func show(_ event: HomeEvent) {
        if let id = event.calendarItemID,
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// Meet, Zoom, Teams or Webex link from the event's URL, place or notes.
    private static func joinURL(_ url: URL?, _ location: String?, _ notes: String?) -> URL? {
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
        func isMeeting(_ url: URL) -> Bool { hosts.contains { url.host()?.hasSuffix($0) == true } }
        if let url, isMeeting(url) { return url }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: isMeeting)
    }
}
