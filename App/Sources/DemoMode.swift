import Foundation
import MailmuleKit

/// Demo mode for screenshots: made-up accounts and mail, no servers, no Keychain.
/// Started by `scripts/demo.sh`, which runs a copy of the app under its own bundle identifier
/// (so it has its own settings) with its own mail folder in a temporary directory.
///
/// Both are required, so the settings, vault and index of real accounts can never be touched.
@MainActor
enum Demo {
    static let bundleID = "app.mailmule.Mailmule.demo"

    /// The demo's mail folder, outside the real vault.
    static let vaultPath: String? = {
        guard Bundle.main.bundleIdentifier == bundleID, UserDefaults.standard.bool(forKey: "MailmuleDemo"),
              let path = UserDefaults.standard.string(forKey: "MailmuleDemoVault"), path.hasPrefix(NSTemporaryDirectory())
                || path.hasPrefix("/tmp/") || path.hasPrefix("/private/") else { return nil }
        return path
    }()

    static var isActive: Bool { vaultPath != nil }

    /// The design review thread (opened by the "thread" screen).
    static var designThreadID: String?

    static let me = EmailAddress(name: "Alex Morgan", address: "alex@northwind.example")
    static let mePersonal = EmailAddress(name: "Alex Morgan", address: "alex@morgan.example")

    static let work = Account(name: "Alex Morgan", email: "alex@northwind.example", imapHost: "imap.northwind.example",
                              smtpHost: "smtp.northwind.example")
    static let personal = Account(name: "Alex Morgan", email: "alex@morgan.example", imapHost: "imap.morgan.example",
                                  smtpHost: "smtp.morgan.example")

    static var settings: AppSettings {
        var settings = AppSettings()
        settings.accounts = [work, personal]
        settings.accountLabels = [work.id: "Northwind", personal.id: "Osobné"]
        settings.primaryAccountID = work.id
        settings.homeName = "Alex"
        settings.vipSenders = ["priya@northwind.example", "emma@morgan.example"]
        settings.savedSearches = [
            SavedSearch(name: "Faktúry", query: "má:prílohu predmet:invoice"),
            SavedSearch(name: "Od Priyi", query: "od:priya"),
        ]
        settings.suggestFromContacts = false
        settings.senderLogos = false
        settings.eventsBackfilled = true
        settings.mailVaultPath = vaultPath ?? ""
        settings.homeNotes = "– Send Lena the signed contract\n– Book the team dinner for Friday\n– Review Tomás's budget sheet"
        return settings
    }

    private static func person(_ name: String, _ address: String) -> EmailAddress {
        EmailAddress(name: name, address: address)
    }

    private static func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
        Date().addingTimeInterval(-(days * 86_400 + hours * 3_600 + minutes * 60))
    }

    private static func file(_ name: String, kilobytes: Int) -> OutgoingAttachment {
        OutgoingAttachment(filename: name, data: Data(repeating: 0x20, count: kilobytes * 1024))
    }

    /// Today at the given local time, as an iCalendar UTC timestamp.
    private static func icsTime(hour: Int, minute: Int = 0) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static var invitation: String {
        """
        BEGIN:VCALENDAR
        PRODID:-//Mailmule//Demo//EN
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:sprint-planning-demo@northwind.example
        DTSTART:\(icsTime(hour: 15))
        DTEND:\(icsTime(hour: 16))
        SUMMARY:Sprint planning
        LOCATION:Room 4B / Google Meet
        ORGANIZER;CN=Marco Rossi:mailto:marco@northwind.example
        ATTENDEE;CN=Alex Morgan;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:alex@northwind.example
        ATTENDEE;CN=Priya Shah;PARTSTAT=ACCEPTED:mailto:priya@northwind.example
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n", with: "\r\n")
    }

    static var workMail: [DemoMessage] {
        let priya = person("Priya Shah", "priya@northwind.example")
        let tomas = person("Tomás Novák", "tomas@northwind.example")
        let marco = person("Marco Rossi", "marco@northwind.example")
        let lena = person("Lena Fischer", "lena@brightside.example")
        let hana = person("Hana Kim", "hana@northwind.example")
        return [
            // 0–2: design review thread, the newest answer unread
            DemoMessage(from: priya, to: [me], cc: [marco], subject: "Design review: onboarding flow v3",
                        markdown: """
                        Hi Alex,

                        the new onboarding flow is ready for review. Main changes:

                        - **3 steps instead of 5**, account setup and import are merged
                        - a progress bar on top, so people know how far along they are
                        - the welcome screen now shows a short video instead of text

                        Prototype and specs are attached. Could you have a look before Thursday?

                        Thanks,
                        Priya
                        """,
                        date: ago(days: 1, hours: 3), labels: ["Design"],
                        attachments: [file("onboarding-v3.pdf", kilobytes: 840), file("flow-diagram.png", kilobytes: 320)]),
            DemoMessage(from: me, to: [priya], cc: [marco], subject: "Re: Design review: onboarding flow v3",
                        markdown: """
                        Looks great, Priya! Two thoughts:

                        1. Can we keep "Skip for now" on the import step? Some teams start empty.
                        2. The video should not autoplay with sound.

                        Otherwise good to go from my side.
                        """,
                        date: ago(days: 1, hours: 1), role: .sent, labels: ["Design"], replyTo: 0),
            DemoMessage(from: priya, to: [me], cc: [marco], subject: "Re: Design review: onboarding flow v3",
                        markdown: """
                        Good points, both done. "Skip for now" is back and the video starts muted.

                        I'll hand it over to engineering tomorrow unless Marco has anything else.
                        """,
                        date: ago(minutes: 25), seen: false, labels: ["Design"], replyTo: 1),
            // 3: invitation for today
            DemoMessage(from: marco, to: [me, priya], subject: "Invitation: Sprint planning @ 15:00",
                        markdown: """
                        Let's plan the next sprint. Please bring your estimates for the onboarding work.

                        Agenda: review of last sprint, onboarding v3, release date.
                        """,
                        date: ago(hours: 2), seen: false, calendar: invitation),
            // 4: budget, starred
            DemoMessage(from: tomas, to: [me], subject: "Q4 budget numbers",
                        markdown: """
                        Hi Alex,

                        attached is the Q4 budget. We're **4 % under plan** overall; marketing is slightly over
                        because of the conference in November.

                        Can you confirm the headcount numbers on the second sheet by Friday?

                        Tomás
                        """,
                        date: ago(hours: 5), seen: false, flagged: true, labels: ["Finance"],
                        attachments: [file("q4-budget.xlsx", kilobytes: 96)]),
            // 5: CI notification
            DemoMessage(from: person("Forge CI", "builds@forge.example"), to: [me],
                        subject: "✅ Build #1842 passed on main",
                        markdown: "All 412 tests passed in 6 min 12 s.\n\nCommit `a3f9c1e` by Priya Shah: *Merge onboarding v3*",
                        date: ago(hours: 7)),
            // 6–7: waiting for Lena's answer (follow-up)
            DemoMessage(from: lena, to: [me], subject: "Contract renewal for 2027",
                        markdown: """
                        Hello Alex,

                        our contract ends in December. We'd like to renew for another year. Could you send
                        us the updated terms?

                        Best regards,
                        Lena Fischer
                        Brightside Studio
                        """,
                        date: ago(days: 4)),
            DemoMessage(from: me, to: [lena], subject: "Re: Contract renewal for 2027",
                        markdown: """
                        Hi Lena,

                        happy to continue! The updated terms are attached; the only change is the support
                        response time, which goes down to 4 hours.

                        Let me know if it works for you.
                        """,
                        date: ago(days: 3), role: .sent, replyTo: 6,
                        attachments: [file("terms-2027.pdf", kilobytes: 210)]),
            // 8: invoice
            DemoMessage(from: person("Cloudhaus Billing", "billing@cloudhaus.example"), to: [me],
                        subject: "Your Cloudhaus invoice for October",
                        markdown: "Thank you for your business. Your invoice **#2026-1043** for **€ 1,280.00** is attached.\n\nIt will be charged on 1 November.",
                        date: ago(days: 2, hours: 4), labels: ["Finance"],
                        attachments: [file("invoice-2026-1043.pdf", kilobytes: 64)]),
            // 9: snoozed until later today
            DemoMessage(from: hana, to: [me], subject: "Frontend candidates – shortlist",
                        markdown: "Here's the shortlist of four candidates for the frontend role. Can we pick two for interviews?",
                        date: ago(days: 2), role: .archive),
            // 10: older, read
            DemoMessage(from: marco, to: [me], subject: "Offsite in Lisbon – save the date",
                        markdown: "Save the date: team offsite in Lisbon, 18–20 November. More details soon!",
                        date: ago(days: 6)),
        ]
    }

    static var personalMail: [DemoMessage] {
        let emma = person("Emma Morgan", "emma@morgan.example")
        return [
            DemoMessage(from: emma, to: [mePersonal], subject: "Sunday lunch?",
                        markdown: "Hi! Are you coming on Sunday? Dad is making his lasagne 🍝\n\nLet me know by Friday. Love, Emma",
                        date: ago(hours: 1, minutes: 10), seen: false),
            DemoMessage(from: person("SkyPort Airlines", "booking@skyport.example"), to: [mePersonal],
                        subject: "Your flight to Lisbon is confirmed",
                        markdown: """
                        **Booking LX7Q2M** · Bratislava → Lisbon

                        Departure 18 November, 07:40 · Seat 14A

                        Your boarding pass is attached. Have a nice trip!
                        """,
                        date: ago(days: 1, hours: 6), attachments: [file("boarding-pass.pdf", kilobytes: 120)]),
            DemoMessage(from: person("Daniel Lee", "daniel@lee.example"), to: [mePersonal],
                        subject: "Book club: November pick",
                        markdown: "The votes are in: we're reading *The Remains of the Day*. See you on the 28th!",
                        date: ago(days: 3, hours: 2)),
            DemoMessage(from: person("Swift Digest", "news@swiftdigest.example"), to: [mePersonal],
                        subject: "Swift Digest #212: concurrency tips, new APIs",
                        markdown: "This week: three ways to avoid actor reentrancy bugs, what's new in SwiftUI, and more.",
                        date: ago(days: 5)),
        ]
    }

    /// What the demo shows after launch: `-MailmuleDemoScreen home|inbox|thread|compose|search|settings`.
    static func showScreen(model: AppModel) {
        let screen = UserDefaults.standard.string(forKey: "MailmuleDemoScreen") ?? "home"
        guard screen != "home" else { return }
        model.showingHome = false
        model.filter = .inbox
        switch screen {
        case "thread":
            // A moment after launch, like a click: right at startup the message view is not ready yet.
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let id = designThreadID { model.openFromHome(id) }
            }
        case "compose":
            model.presentCompose(ComposeDraft(accountID: work.id, to: "Priya Shah <priya@northwind.example>",
                                              subject: "Launch checklist", body: """
                Hi Priya,

                here's what's left before we **ship onboarding v3**:

                - [x] Final copy review
                - [ ] Update the help center articles
                - [ ] Record the welcome video in **4K**

                > Let's aim for *Thursday*, so we have Friday as a buffer.

                Thanks!
                Alex
                """))
        case "search":
            model.searchText = "má:prílohu"
        case "settings":
            model.settingsCategory = .appearance
            model.settingsOpenRequest += 1
        default:
            break
        }
    }

    /// Fills the empty demo vault: mail, a follow-up, a snooze and an AI summary.
    static func seed(model: AppModel, index: MailIndex, services: [String: AccountService]) async {
        guard let workService = services[work.id], let personalService = services[personal.id] else { return }
        do {
            let workIDs = try await workService.seedDemo(workMail)
            designThreadID = workIDs[2].threadID
            try await personalService.seedDemo(personalMail)
            let calendar = Calendar.current
            try await index.setFollowUp(threadID: workIDs[7].threadID, account: work.id,
                                        due: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date(), since: ago(days: 3))
            try await index.setSnooze(threadID: workIDs[9].threadID, account: work.id,
                                      until: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date())
            try await index.setSummary("""
                - Priya finished onboarding flow v3: 3 steps instead of 5, a progress bar and a welcome video.
                - Alex asked to keep "Skip for now" on the import step and to start the video muted.
                - Both changes are done; Priya hands it to engineering tomorrow unless Marco objects.
                """, threadID: workIDs[2].threadID, latestKey: workIDs[2].key)
            model.log("demo: pošta vytvorená")
        } catch {
            model.log("demo: \(error)")
        }
    }
}
