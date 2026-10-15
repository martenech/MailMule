import MailmuleKit
import SwiftUI
import UniformTypeIdentifiers

/// Every attachment in the mail: filter by type, search by name, sender or subject; space or double-click
/// previews, drag to Finder saves, the message shows on the right.
struct AttachmentsView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [AttachmentItem] = []
    @State private var kind: AttachmentItem.Kind = .all
    @State private var query = ""
    @State private var selection: AttachmentItem.ID?
    @State private var loaded = false

    private var visible: [AttachmentItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return items.filter { item in
            (kind == .all || item.kind == kind) && (needle.isEmpty || [
                item.filename, item.message.subject, item.message.from?.displayName ?? "", item.message.from?.address ?? "",
            ].contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) })
        }
    }

    var body: some View {
        let visible = self.visible
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Hľadať prílohu, odosielateľa, predmet…", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $kind) {
                    ForEach(AttachmentItem.Kind.allCases, id: \.self) { kind in
                        Text(kind == .all ? kind.rawValue : "\(kind.rawValue) \(count(kind))").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Žiadne prílohy" : "Nič sa nenašlo", systemImage: "paperclip")
            } else {
                List(visible, selection: $selection) { item in
                    AttachmentRow(item: item)
                        .tag(item.id)
                        .onDrag {
                            guard let url = model.attachmentFile(item) else { return NSItemProvider() }
                            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                        }
                        .contextMenu {
                            Button("Náhľad") { preview(item) }
                            Button("Otvoriť v aplikácii") { model.openAttachment(item.filename, in: item.message) }
                            Divider()
                            Button("Uložiť do Stiahnutých") { model.saveAttachment(item.filename, in: item.message, toDownloads: true) }
                            Button("Uložiť ako…") { model.saveAttachment(item.filename, in: item.message, toDownloads: false) }
                            Divider()
                            Button("Otvoriť vlákno v novom okne") { model.openThreadWindow(item.message.threadID) }
                        }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: AttachmentItem.ID.self, menu: { _ in }, primaryAction: { ids in
                    if let id = ids.first, let item = items.first(where: { $0.id == id }) { preview(item) }
                })
                .onKeyPress(.space) {
                    guard let id = selection, let item = items.first(where: { $0.id == id }) else { return .ignored }
                    preview(item)
                    return .handled
                }
            }
            Divider()
            Text("\(visible.count) \(visible.count == 1 ? "príloha" : visible.count < 5 ? "prílohy" : "príloh") · medzerník náhľad · potiahnutím do Findera uložíte")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .themedChrome()
        .task(id: model.accountScope) {
            items = await model.attachmentItems()
            loaded = true
        }
        .onChange(of: selection) {
            if let id = selection, let item = items.first(where: { $0.id == id }) { model.showMessage(of: item) }
        }
    }

    private func count(_ kind: AttachmentItem.Kind) -> Int {
        items.filter { $0.kind == kind }.count
    }

    private func preview(_ item: AttachmentItem) {
        model.previewAttachments(in: item.message, startingAt: item.filename)
    }
}

private struct AttachmentRow: View {
    @Environment(AppModel.self) private var model
    let item: AttachmentItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(item.message.from?.displayName ?? "")
                    Text("·")
                    Text(item.message.subject.isEmpty ? "(bez predmetu)" : item.message.subject)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(ThreadRow.shortDate(item.message.date))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}
