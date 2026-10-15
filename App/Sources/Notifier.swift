import AppKit
import MailmuleKit
import UserNotifications

/// System notifications for new mail and the unread count on the Dock icon.
@MainActor
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Asks for permission when it was never asked; returns the resulting state.
    static func ensureAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return await center.notificationSettings().authorizationStatus
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Opens Mailmule in System Settings → Notifications.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
        NSWorkspace.shared.open(url)
    }

    /// "Poslať skúšobné upozornenie" in Settings, with the current sound and preview settings.
    static func sendTest(settings: AppSettings) {
        let soundName = settings.accountSounds.values.first { !$0.isEmpty && $0 != "none" } ?? ""
        let content = UNMutableNotificationContent()
        content.title = "Mailmule"
        content.subtitle = "Skúšobné upozornenie"
        if settings.notifyPreview { content.body = "Takto bude vyzerať upozornenie na novú poštu." }
        if settings.notifySound {
            if soundName.isEmpty { content.sound = .default } else { NSSound(named: soundName)?.play() }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID())", content: content, trigger: nil))
    }

    static func notify(_ message: StoredMessage, accountEmail: String?, settings: AppSettings) {
        let soundName = settings.accountSounds[message.accountID] ?? ""
        let silent = !settings.notifySound || soundName == "none"
        guard settings.notifyBanners else {
            // Sound only: play it without a banner.
            if !silent { (soundName.isEmpty ? NSSound(named: "Glass") : NSSound(named: soundName))?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = message.from?.displayName ?? "Nová správa"
        content.subtitle = [message.subject.isEmpty ? "(bez predmetu)" : message.subject, accountEmail]
            .compactMap { $0 }.joined(separator: " · ")
        if settings.notifyPreview { content.body = message.snippet }
        if !silent {
            // Notification sounds must live in the app or ~/Library/Sounds, so system sounds are played directly.
            if soundName.isEmpty { content.sound = .default } else { NSSound(named: soundName)?.play() }
        }
        content.threadIdentifier = message.threadID
        content.userInfo = ["thread": message.threadID]
        let request = UNNotificationRequest(identifier: message.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// "Bez odpovede": a follow-up came due and the thread is back in the inbox.
    static func notifyFollowUp(subject: String, threadID: String, settings: AppSettings) {
        guard settings.notifyBanners else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bez odpovede"
        content.subtitle = subject.isEmpty ? "(bez predmetu)" : subject
        content.body = "Vlákno je späť v Doručenej pošte."
        if settings.notifySound { content.sound = .default }
        content.userInfo = ["thread": threadID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "follow-\(threadID)", content: content, trigger: nil))
    }

    /// Sounds from /System/Library/Sounds, for the per-account picker.
    static let systemSounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    static func setDockBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
