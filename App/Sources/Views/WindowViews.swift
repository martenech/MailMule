import MailmuleKit
import SwiftUI

/// A thread in a window of its own (double-click in the list, or "Otvoriť v novom okne").
struct ThreadWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let threadID: String
    @State private var messages: [StoredMessage] = []

    var body: some View {
        Group {
            if messages.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(messages.last?.subject.baseSubject.nonEmpty ?? "(bez predmetu)")
                            .font(.system(size: 22, weight: .bold))
                            .textSelection(.enabled)
                        ForEach(messages) { message in
                            MessageCard(message: message,
                                        initiallyExpanded: message.id == messages.last?.id || !message.seen)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
                .environment(\.threadWindowContext, ThreadWindowContext(threadID: threadID, messages: messages))
            }
        }
        .navigationTitle(messages.last?.subject.baseSubject.nonEmpty ?? "Vlákno")
        .toolbar {
            ToolbarItemGroup {
                Button { model.reply(all: false, in: messages) } label: { Label("Odpovedať", systemImage: "arrowshape.turn.up.left") }
                    .help("Odpovedať")
                Button { model.reply(all: true, in: messages) } label: { Label("Odpovedať všetkým", systemImage: "arrowshape.turn.up.left.2") }
                    .help("Odpovedať všetkým")
                Button { model.forward(in: messages) } label: { Label("Preposlať", systemImage: "arrowshape.turn.up.right") }
                    .help("Preposlať")
            }
            ToolbarItemGroup {
                Button {
                    model.move([threadID], to: .archive)
                    dismissWindow()
                } label: { Label("Archivovať", systemImage: "archivebox") }
                    .help("Archivovať a zavrieť okno")
                Button {
                    model.move([threadID], to: .trash)
                    dismissWindow()
                } label: { Label("Do koša", systemImage: "trash") }
                    .help("Presunúť do koša a zavrieť okno")
            }
        }
        .task(id: threadID) { messages = await model.threadWindowMessages(threadID) }
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// The editor in a window of its own; closes when the message is sent or the draft closed.
struct ComposeWindowView: View {
    @Environment(AppModel.self) private var model
    let draftID: UUID

    var body: some View {
        if let draft = model.windowDrafts[draftID] ?? model.drafts.first(where: { $0.id == draftID }) {
            ComposeView(draft: draft, inWindow: true)
                .onDisappear { model.windowDrafts[draftID] = nil }
        } else {
            ContentUnavailableView("Koncept sa nenašiel", systemImage: "doc.questionmark")
                .frame(minWidth: 500, minHeight: 300)
        }
    }
}
