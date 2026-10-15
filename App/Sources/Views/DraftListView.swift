import MailmuleKit
import SwiftUI

/// Unsent messages; selecting one continues writing it.
struct DraftListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.showingScheduled ? model.scheduledDrafts : model.visibleDrafts) { draft in
                Button {
                    model.openDraft(draft)
                } label: {
                    DraftRow(draft: draft)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Pokračovať v písaní") { model.openDraft(draft) }
                    if draft.outbox {
                        Button("Skúsiť odoslať teraz") { model.retryOutbox() }
                    }
                    if draft.scheduledAt != nil {
                        Button(draft.outbox ? "Neodosielať (presunúť do konceptov)" : "Zrušiť plán (presunúť do konceptov)") {
                            var plain = draft
                            plain.scheduledAt = nil
                            plain.outbox = false
                            model.saveDraft(plain)
                        }
                    }
                    Button("Zahodiť", role: .destructive) { model.discardDraft(draft.id) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.showingScheduled && model.scheduledDrafts.isEmpty {
                ContentUnavailableView("Nič nie je naplánované", systemImage: "calendar.badge.clock",
                                       description: Text("V okne správy zvoľ pri Odoslať „Odoslať neskôr…“."))
            } else if !model.showingScheduled && model.visibleDrafts.isEmpty {
                ContentUnavailableView("Žiadne koncepty", systemImage: "doc",
                                       description: Text("Rozpísané správy sa ukladajú automaticky."))
            }
        }
        .navigationTitle(model.showingScheduled ? "Naplánované" : "Koncepty")
    }
}

private struct DraftRow: View {
    @Environment(AppModel.self) private var model
    let draft: SavedDraft

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.settings.accounts.count > 1 && model.accountScope == nil {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(model.accountColor(draft.accountID))
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recipients)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if draft.outbox {
                        Label("Čaká na spojenie", systemImage: "tray.and.arrow.up")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if let scheduledAt = draft.scheduledAt {
                        Label(SnoozeOption.describe(scheduledAt), systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.themeAccent)
                    } else {
                        Text(ThreadRow.shortDate(draft.updated))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(draft.subject.isEmpty ? "(bez predmetu)" : draft.subject)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !draft.attachments.isEmpty {
                        Image(systemName: "paperclip")
                    }
                    Text(preview)
                        .lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let error = draft.sendError {
                    Label(draft.outbox ? "\(error) · ďalší pokus \(draft.scheduledAt.map { SnoozeOption.describe($0) } ?? "čoskoro")" : error,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(draft.outbox ? Color.orange : Color.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var recipients: String {
        let names = AddressParser.parseList(draft.to).map(\.displayName)
        return names.isEmpty ? "Bez príjemcu" : names.joined(separator: ", ")
    }

    /// The new text, without the quoted original.
    private var preview: String {
        draft.body.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(">") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }
}
