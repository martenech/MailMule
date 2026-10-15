import AppKit
import MailmuleKit
import SwiftUI
import UserNotifications

/// Delays quitting until pending archive/delete actions have reached the server,
/// and opens the thread when a new-mail notification is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Finder and other apps: Services → "Poslať e-mailom v Mailmule".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func sendFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        model?.composeWithFiles(urls)
    }

    @objc func sendText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let text = pasteboard.string(forType: .string), !text.isEmpty { model?.composeWithText(text) }
    }

    /// Without this, macOS drops the banner while Mailmule is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let thread = response.notification.request.content.userInfo["thread"] as? String,
              let url = URL(string: ThreadMarkdown.link(threadID: thread)) else { return }
        await MainActor.run {
            NSApp.activate()
            model?.handle(url: url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.pendingActions.isEmpty || model.pendingSend != nil else { return .terminateNow }
        Task { @MainActor in
            await model.flushPendingActions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MailmuleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Mailmule", id: "main") {
            MainView()
                .environment(model)
                .tint(ThemeStore.shared.accent)
                .onAppear {
                    appDelegate.model = model
                    ThemeStore.shared.applyAppearance()
                }
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nová správa") { model.composeNew() }
                    .keyboardShortcut("n")
            }
            CommandGroup(before: .sidebar) {
                ListViewMenuItems()
                    .environment(model)
                Divider()
            }
            CommandMenu("Pošta") {
                Button("Paleta príkazov…") { model.isPaletteOpen = true }
                    .keyboardShortcut("k")
                    .disabled(model.compose != nil)
                Button("Synchronizovať") { Task { await model.syncAll() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Doručená pošta") { model.showingDrafts = false; model.filter = .inbox }
                    .keyboardShortcut("1")
                Button("Odoslané") { model.showingDrafts = false; model.filter = .sent }
                    .keyboardShortcut("2")
                Button("Archív") { model.showingDrafts = false; model.filter = .archive }
                    .keyboardShortcut("3")
                Button("Koncepty") { model.showingDrafts = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Kôš") { model.showingDrafts = false; model.filter = .trash }
                    .keyboardShortcut("4")
                Button("Všetka pošta") { model.showingDrafts = false; model.filter = .all }
                    .keyboardShortcut("5")
                Divider()
                Button("Tlačiť vlákno…") { model.printSelectedThread() }
                    .keyboardShortcut("p")
                    .disabled(model.messages.isEmpty || model.compose != nil)
                Button("Exportovať vlákno ako PDF…") { model.exportSelectedThreadAsPDF() }
                    .disabled(model.messages.isEmpty)
                Divider()
                Button("Otvoriť mail vault vo Finderi") { model.revealVault() }
            }
        }

        WindowGroup("Vlákno", id: "thread", for: String.self) { $threadID in
            if let threadID {
                ThreadWindowView(threadID: threadID)
                    .environment(model)
                    .tint(ThemeStore.shared.accent)
            }
        }
        .defaultSize(width: 860, height: 820)

        WindowGroup("Náhľad", id: "viewer", for: String.self) { $sessionID in
            if let sessionID {
                AttachmentViewer(sessionID: sessionID)
                    .environment(model)
                    .tint(ThemeStore.shared.accent)
            }
        }
        .defaultSize(width: 900, height: 1000)

        WindowGroup("Nová správa", id: "compose", for: UUID.self) { $draftID in
            if let draftID {
                ComposeWindowView(draftID: draftID)
                    .environment(model)
                    .tint(ThemeStore.shared.accent)
            }
        }
        .defaultSize(width: 780, height: 680)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
