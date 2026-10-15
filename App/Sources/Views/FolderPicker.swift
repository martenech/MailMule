import MailmuleKit
import SwiftUI

/// "Move to…" picker (`v`, like Superhuman): type to filter, Enter moves the thread.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    let threadIDs: [String]
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Target: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let depth: Int
        let action: @MainActor () -> Void
    }

    private var targets: [Target] {
        var list = [
            Target(id: "inbox", title: "Doručená pošta", systemImage: "tray", depth: 0) { model.move(threadIDs, to: .inbox) },
            Target(id: "archive", title: "Archív", systemImage: "archivebox", depth: 0) { model.move(threadIDs, to: .archive) },
            Target(id: "trash", title: "Kôš", systemImage: "trash", depth: 0) { model.move(threadIDs, to: .trash) },
        ]
        list += model.folders(forThreads: threadIDs).map { folder in
            Target(id: folder.name, title: folder.displayName, systemImage: "folder", depth: folder.depth) {
                model.move(threadIDs, toFolder: folder)
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        // When filtering, show flat names so matches are easy to scan.
        return list.filter { fold($0.title).contains(fold(trimmed)) }
            .map { Target(id: $0.id, title: $0.title, systemImage: $0.systemImage, depth: 0, action: $0.action) }
    }

    var body: some View {
        let targets = self.targets
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                TextField(threadIDs.count > 1 ? "Presunúť \(threadIDs.count) vlákien do…" : "Presunúť do…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .focused($focused)
                    .onSubmit { run(targets) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, targets.count - 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { selection = 0 }
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(targets.enumerated()), id: \.element.id) { offset, target in
                            Label(target.title, systemImage: target.systemImage)
                                .padding(.leading, CGFloat(target.depth) * 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(offset == selection ? Color.themeAccent.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = offset
                                    run(targets)
                                }
                        }
                        if targets.isEmpty {
                            Text("Žiadny priečinok sa nezhoduje").foregroundStyle(.secondary).padding(12)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
    }

    private func run(_ targets: [Target]) {
        guard targets.indices.contains(selection) else { return }
        let target = targets[selection]
        close()
        target.action()
    }

    private func close() {
        model.folderPickerThreadIDs = nil
    }
}
