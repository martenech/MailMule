import MailmuleKit
import QuickLook
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsSetup {
                SetupView()
            } else if model.showingHome {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    HomeView()
                }
                .toolbar(removing: .title)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } content: {
                    Group {
                        if model.showingAttachments { AttachmentsView() }
                        else if model.showingDrafts { DraftListView() } else { ThreadListView() }
                    }
                    .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 560)
                } detail: {
                    ThreadDetailView()
                }
                .toolbar(removing: .title)
                .onAppear { columns = model.settings.threeColumns ? .all : .doubleColumn }
                .onChange(of: model.settings.threeColumns) { columns = model.settings.threeColumns ? .all : .doubleColumn }
            }
        }
        .task { await model.start() }
        .onChange(of: model.settingsOpenRequest) { openSettings() }
        .onChange(of: model.windowRequest) {
            switch model.windowRequest {
            case .thread(let id)?: openWindow(id: "thread", value: id)
            case .compose(let id)?: openWindow(id: "compose", value: id)
            case .viewer(let id)?: openWindow(id: "viewer", value: id)
            case nil: return
            }
            model.windowRequest = nil
        }
        .confirmationDialog("Stiahnuť jazykový model?", isPresented: Binding(
            get: { model.assistantDownloadRequest != nil },
            set: { if !$0 { model.assistantDownloadRequest = nil } }), presenting: model.assistantDownloadRequest) { request in
            Button("Stiahnuť (\(model.settings.assistantModel.size.formatted(.number.precision(.fractionLength(1)))) GB)") {
                model.confirmAssistantDownload(request)
            }
        } message: { _ in
            Text("Súhrny a návrhy odpovedí robí model \(model.settings.assistantModel.title.components(separatedBy: " –").first ?? "") priamo v tomto Macu – pošta nikam neodchádza. Stiahne sa raz z Hugging Face; zmazať ho môžete v Nastaveniach → Asistent.")
        }
        .onOpenURL { model.handle(url: $0) }
        .sheet(item: $model.personSheet) { sheet in
            PersonCard(address: sheet.address)
                .overlay(alignment: .topTrailing) {
                    Button { model.personSheet = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .padding(10)
                }
        }
        .sheet(item: $model.compose) { draft in
            ComposeView(draft: draft)
        }
        .overlay {
            if model.isPaletteOpen { CommandPalette() }
            if let ids = model.tagPickerThreadIDs { TagPicker(threadIDs: ids) }
            if let ids = model.folderPickerThreadIDs { FolderPicker(threadIDs: ids) }
            if let ids = model.snoozePickerThreadIDs { SnoozePicker(threadIDs: ids) }
        }
        .overlay(alignment: .bottom) {
            if let pending = model.pendingSend {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("Odosiela sa o \(left) s")
                            .monospacedDigit()
                    }
                    Button("Vrátiť") { model.undoSend() }
                        .buttonStyle(.link)
                    Button("Odoslať hneď") { Task { await model.flushPendingSend() } }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                    Text("z").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(pending.id)
            } else if let action = model.pendingActions.last {
                HStack(spacing: 12) {
                    Text(action.title)
                    Button("Vrátiť") { model.undoLast() }
                        .buttonStyle(.link)
                    Text("z").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(action.id)
            } else if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.pendingActions.last?.id)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .alert("Chyba", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(KeyMonitor {
            model.isPaletteOpen || model.tagPickerThreadIDs != nil || model.folderPickerThreadIDs != nil
                || model.snoozePickerThreadIDs != nil
                ? false : model.handleKey($0)
        })
    }
}
