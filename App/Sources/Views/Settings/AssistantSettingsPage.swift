import SwiftUI

/// The on-device language model: which one, download, delete.
struct AssistantSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var refresh = 0
    @State private var confirmDelete: LocalModel.Choice?

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .assistant) {
            SettingsCard {
                SettingsToggle("Asistent", detail: "Tlačidlo ✨ Zhrnúť nad vláknom a ✨ Navrhnúť odpoveď v rýchlej odpovedi.",
                               symbol: "sparkles", isOn: $model.settings.assistantEnabled)
            }

            SettingsCard("Model", subtitle: "Beží priamo v tomto Macu (MLX na grafickom čipe). Text pošty nikam neodchádza. Model sa načíta, keď ho treba, a po 5 minútach nečinnosti sa uvoľní z pamäte.") {
                VStack(spacing: 8) {
                    ForEach(LocalModel.Choice.allCases) { choice in
                        modelRow(choice)
                    }
                }
                .id(refresh)
                if let status = AssistantStatus.text(model.localModel.state) {
                    HStack(spacing: 8) {
                        if case .downloading(let fraction) = model.localModel.state {
                            ProgressView(value: fraction).frame(width: 200)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard(tint: .gray) {
                Label("Malé modely zvládajú súhrny dobre, slovenské návrhy odpovedí bývajú niekedy kostrbaté – vždy si ich prečítajte pred odoslaním.",
                      systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Zmazať model \(confirmDelete?.title ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { choice in
            Button("Zmazať", role: .destructive) {
                model.localModel.delete(choice)
                refresh += 1
            }
        } message: { choice in
            Text("Uvoľní sa \(StorageSettingsPage.format(model.localModel.downloadedSize(choice))). Pri ďalšom použití sa stiahne znova.")
        }
        .onChange(of: model.localModel.state) { refresh += 1 }
    }

    private func modelRow(_ choice: LocalModel.Choice) -> some View {
        let downloaded = model.localModel.isDownloaded(choice)
        let selected = model.settings.assistantModel == choice
        return HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.themeAccent : .secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(downloaded ? "Stiahnutý · \(StorageSettingsPage.format(model.localModel.downloadedSize(choice)))"
                                : "Nestiahnutý · \(choice.size.formatted(.number.precision(.fractionLength(1)))) GB")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloaded {
                Button("Zmazať") { confirmDelete = choice }
            } else {
                Button("Stiahnuť") {
                    model.settings.assistantModel = choice
                    Task { _ = try? await model.localModel.prepare(choice) }
                }
                .disabled(isBusy)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(selected ? 0.06 : 0.02), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.settings.assistantModel = choice }
    }

    private var isBusy: Bool {
        switch model.localModel.state {
        case .downloading, .loading, .generating: true
        default: false
        }
    }
}
