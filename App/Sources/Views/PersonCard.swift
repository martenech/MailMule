import MailmuleKit
import SwiftUI

/// Everything with one person or company: how much and how recently you wrote, recent threads and attachments.
struct PersonCard: View {
    @Environment(AppModel.self) private var model
    let address: EmailAddress
    @State private var stats: PersonStats?
    @State private var threads: [ThreadSummary] = []
    @State private var attachments: [AttachmentItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SenderAvatar(name: address.displayName, address: address.address, emphasized: true, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(address.displayName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(address.address).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let domain = AvatarStore.organizationDomain(of: address.address) {
                        Text(domain).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            if let stats {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(stats.messages) \(plural(stats.messages, "správa", "správy", "správ")) v \(stats.threads) \(plural(stats.threads, "vlákne", "vláknach", "vláknach"))",
                          systemImage: "envelope")
                    if let first = stats.first {
                        Label("Prvý kontakt \(first.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                    }
                    if let date = stats.lastFromThem {
                        Label("Naposledy písal(a) \(date.formatted(.relative(presentation: .named)))", systemImage: "arrow.down.left")
                    }
                    if let date = stats.lastToThem {
                        Label("Naposledy ste písali \(date.formatted(.relative(presentation: .named)))", systemImage: "arrow.up.right")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            if !threads.isEmpty {
                section("Posledné vlákna") {
                    ForEach(threads.prefix(5)) { thread in
                        Button { model.selectedThreadID = thread.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(thread.subject.isEmpty ? "(bez predmetu)" : thread.subject)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(ThreadRow.shortDate(thread.date)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                // What the mail is about: the beginning of its text.
                                Text(Self.gist(thread.snippet))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Otvoriť vlákno")
                    }
                }
            }
            if !attachments.isEmpty {
                section("Prílohy") {
                    ForEach(attachments.prefix(5)) { item in
                        Button { model.previewAttachments(in: item.message, startingAt: item.filename) } label: {
                            HStack {
                                Image(systemName: "paperclip").foregroundStyle(.secondary)
                                Text(item.filename).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(ThreadRow.shortDate(item.message.date)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Náhľad")
                    }
                }
            }
            Divider()
            HStack {
                Button("Napísať") { model.composeTo(address) }
                Button("Všetko s ním") {
                    model.showingAttachments = false
                    model.showingDrafts = false
                    model.searchText = "s:\(address.address)"
                }
                Spacer()
                Menu {
                    let vip = AppSettings.matches(address.address, model.settings.vipSenders)
                    Button(vip ? "Odobrať z VIP" : "Pridať do VIP") {
                        let entry = address.address.lowercased()
                        if vip { model.settings.vipSenders.removeAll { $0 == entry } } else { model.settings.vipSenders.append(entry) }
                    }
                    Button("Kopírovať adresu") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address.address, forType: .string)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 500)
        .task {
            stats = await model.personStats(address.address)
            threads = await model.threads(with: address.address)
            attachments = await model.attachmentItems().filter {
                $0.message.from?.address.caseInsensitiveCompare(address.address) == .orderedSame
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    /// The new text of a preview: without the quoted original and the signature that follow it.
    static func gist(_ snippet: String) -> String {
        var text = snippet
        let cuts = [#"\s(Dňa|On|Am|Dne)\s.{4,80}?(napísal|napsal|wrote|schrieb)"#, #"\s(From|Od):\s"#,
                    #"\s-{3,}\s?(Preposlaná|Forwarded|Pôvodná|Original)"#, #"\s(S pozdravom|S pozdravem|Ďakujem a zdravím|Best regards|Kind regards|Regards),?\s"#]
        for pattern in cuts {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]), text.distance(from: text.startIndex, to: range.lowerBound) > 15 {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        n == 1 ? one : (2...4).contains(n) ? few : many
    }
}

extension AppModel {
    func personStats(_ address: String) async -> PersonStats? {
        try? await index?.personStats(address: address, ownAddresses: settings.accounts.map(\.email))
    }

    func threads(with address: String) async -> [ThreadSummary] {
        (try? await index?.threads(filter: .all, search: "s:\(address)", limit: 20)) ?? []
    }

    func composeTo(_ address: EmailAddress) {
        guard let accountID = defaultSenderID else { return }
        presentCompose(ComposeDraft(accountID: accountID, to: Self.fieldValue(address), body: signatureBlock(accountID, kind: .new)))
    }
}
