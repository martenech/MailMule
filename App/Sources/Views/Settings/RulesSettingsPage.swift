import MailmuleKit
import SwiftUI

struct RulesSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MailRule?
    @State private var running: UUID?

    var body: some View {
        @Bindable var model = model
        SettingsPage(category: .rules) {
            SettingsCard("Odporúčané automatizácie", subtitle: "Začnite hotovým pravidlom a upravte si ho.") {
                VStack(spacing: 8) {
                    ForEach(RuleTemplate.all) { template in
                        Button { editing = template.rule() } label: {
                            TemplateCard(template: template)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            SettingsCard("Aktívne pravidlá", subtitle: "Platia pre novú poštu v Doručenej, zhora nadol. Na poštu, ktorá už v Doručenej je, ich spustíte v ponuke ⋯ pri pravidle.", accessory: {
                Button { editing = MailRule(name: "", conditions: [RuleCondition(field: .sender)], actions: [.archive]) } label: {
                    Label("Nové pravidlo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }) {
                if model.settings.rules.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Zatiaľ žiadne pravidlá").font(.system(size: 13, weight: .medium))
                        Text("Vyberte odporúčané pravidlo vyššie alebo vytvorte nové.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.settings.rules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
            }

            SettingsCard("Rýchle akcie", subtitle: "Gesto na trackpade (dva prsty) alebo na Magic Mouse (jeden prst), keď je kurzor nad vláknom v zozname – ako v Mail.app. Na myši bez gest použite pravý klik alebo klávesy.") {
                SettingsRows {
                    SettingsRow("Potiahnutie doprava", symbol: "rectangle.and.hand.point.up.left") {
                        swipePicker($model.settings.swipeLeading)
                    }
                    SettingsRow("Potiahnutie doľava", symbol: "rectangle.and.hand.point.up.left") {
                        swipePicker($model.settings.swipeTrailing)
                    }
                    SettingsToggle("Po archivácii označiť ako prečítané",
                                   detail: "Platí pre archiváciu klávesom E, potiahnutím aj pravidlami.",
                                   symbol: "envelope.open", isOn: $model.settings.markReadOnArchive)
                }
            }
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule)
        }
    }

    private func swipePicker(_ selection: Binding<SwipeAction>) -> some View {
        Picker("", selection: selection) {
            ForEach(SwipeAction.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .labelsHidden()
        .frame(width: 220)
    }

    private func ruleRow(_ rule: MailRule) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in update(rule.id) { $0.enabled = on } }))
                .toggleStyle(.switch)
                .labelsHidden()
            Image(systemName: RuleText.symbol(for: rule))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name.isEmpty ? "Bez názvu" : rule.name).font(.system(size: 13, weight: .semibold))
                Text(RuleText.conditions(rule, model: model))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(RuleText.actions(rule, model: model), systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.themeAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if running == rule.id { ProgressView().controlSize(.small) }
            Menu {
                Button("Upraviť…") { editing = rule }
                Button("Spustiť teraz na Doručenú poštu") { runNow(rule) }
                Button("Duplikovať") {
                    var copy = rule
                    copy.id = UUID()
                    copy.name += " (kópia)"
                    copy.createdAt = Date()
                    model.settings.rules.append(copy)
                }
                Divider()
                Button("Posunúť vyššie") { move(rule.id, by: -1) }
                    .disabled(model.settings.rules.first?.id == rule.id)
                Button("Posunúť nižšie") { move(rule.id, by: 1) }
                    .disabled(model.settings.rules.last?.id == rule.id)
                Divider()
                Button("Odstrániť", role: .destructive) { model.settings.rules.removeAll { $0.id == rule.id } }
            } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(rule.enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = rule }
    }

    private func runNow(_ rule: MailRule) {
        running = rule.id
        Task {
            await model.runRuleNow(rule)
            running = nil
        }
    }

    private func update(_ id: UUID, _ change: (inout MailRule) -> Void) {
        guard let index = model.settings.rules.firstIndex(where: { $0.id == id }) else { return }
        change(&model.settings.rules[index])
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = model.settings.rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard model.settings.rules.indices.contains(target) else { return }
        model.settings.rules.swapAt(index, target)
    }
}

// MARK: - Templates

@MainActor
private struct RuleTemplate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let rule: () -> MailRule

    static let all = [
        RuleTemplate(id: "newsletters", title: "Archivovať newslettre po 7 dňoch",
                     detail: "Staršie newslettre a reklamy sa samy upracú z Doručenej.", symbol: "archivebox", color: .green) {
            // Banks and insurers also send List-Unsubscribe, so statements and reminders are kept.
            MailRule(name: "Newslettre po 7 dňoch",
                     conditions: [RuleCondition(field: .newsletter),
                                  RuleCondition(field: .subject, op: .notContains,
                                                value: "faktúra, faktura, výpis, upomienka, zmluva, objednávka, platba, invoice")],
                     actions: [.archive], afterDays: 7)
        },
        RuleTemplate(id: "invoices", title: "Označiť faktúry hviezdičkou",
                     detail: "Faktúry dostanú hviezdičku a štítok Faktúry.", symbol: "star", color: .yellow) {
            MailRule(name: "Faktúry",
                     matchAll: false,
                     conditions: [RuleCondition(field: .subject, value: "faktúra, faktura, invoice, vyúčtovanie"),
                                  RuleCondition(field: .body, value: "faktúru v prílohe, faktúra je v prílohe")],
                     actions: [.star, .tag("Faktúry")])
        },
        RuleTemplate(id: "notifications", title: "Notifikácie bez upozornenia",
                     detail: "Bankové a systémové notifikácie prídu potichu ako prečítané.", symbol: "bell.slash", color: .blue) {
            MailRule(name: "Notifikácie potichu", matchAll: false,
                     conditions: [RuleCondition(field: .sender, value: "notifikacie@, notifications@, notification@, notify@, alerts@")],
                     actions: [.noNotification, .markRead])
        },
    ]
}

private struct TemplateCard: View {
    let template: RuleTemplate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: template.symbol)
                .font(.system(size: 16))
                .foregroundStyle(template.color)
                .frame(width: 34, height: 34)
                .background(template.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).font(.system(size: 13, weight: .semibold))
                Text(template.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("Použiť").font(.system(size: 12)).foregroundStyle(Color.themeAccent)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

// MARK: - Describing rules

@MainActor
enum RuleText {
    static func fieldTitle(_ field: RuleCondition.Field) -> String {
        switch field {
        case .sender: "Odosielateľ"
        case .recipient: "Príjemca"
        case .subject: "Predmet"
        case .body: "Text správy"
        case .attachmentSize: "Veľkosť príloh"
        case .hasAttachment: "Má prílohu"
        case .newsletter: "Je newsletter"
        }
    }

    static func operators(for field: RuleCondition.Field) -> [RuleCondition.Operator] {
        switch field {
        case .attachmentSize: [.greaterThan]
        case .hasAttachment, .newsletter: []
        case .sender, .recipient: [.contains, .notContains, .equals, .endsWith]
        case .subject, .body: [.contains, .notContains, .equals]
        }
    }

    static func operatorTitle(_ op: RuleCondition.Operator) -> String {
        switch op {
        case .contains: "obsahuje"
        case .notContains: "neobsahuje"
        case .equals: "je presne"
        case .endsWith: "končí na"
        case .greaterThan: "je väčšia ako (MB)"
        }
    }

    static func condition(_ condition: RuleCondition) -> String {
        switch condition.field {
        case .hasAttachment: "správa má prílohu"
        case .newsletter: "je to newsletter"
        case .attachmentSize: "prílohy nad \(condition.value) MB"
        default: "\(fieldTitle(condition.field).lowercased()) \(operatorTitle(condition.op)) „\(condition.value)“"
        }
    }

    static func conditions(_ rule: MailRule, model: AppModel) -> String {
        var text = "Ak " + rule.conditions.map(condition).joined(separator: rule.matchAll ? " a " : " alebo ")
        if let days = rule.afterDays { text += ", po \(days) \(days == 1 ? "dni" : "dňoch") v Doručenej" }
        if let account = rule.accountID.flatMap(model.account) { text += " (\(model.accountTitle(account)))" }
        return text
    }

    static func actions(_ rule: MailRule, model: AppModel) -> String {
        let text = rule.actions.map(model.describe).joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func symbol(for rule: MailRule) -> String {
        switch rule.conditions.first?.field {
        case .sender, .recipient: "person"
        case .subject, .body: "doc.text"
        case .attachmentSize, .hasAttachment: "paperclip"
        case .newsletter: "newspaper"
        case nil: "bolt"
        }
    }
}

// MARK: - Editor

private struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: MailRule

    private var isNew: Bool { !model.settings.rules.contains { $0.id == rule.id } }

    private var isValid: Bool {
        !rule.actions.isEmpty
            && rule.conditions.contains { $0.field.needsNoValue || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            && !rule.actions.contains { action in
                switch action {
                case .tag(let tag): tag.trimmingCharacters(in: .whitespaces).isEmpty
                case .moveToFolder(let mailbox): mailbox.isEmpty
                default: false
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isNew ? "Nové pravidlo" : "Upraviť pravidlo").font(.title2.weight(.bold))
                    HStack {
                        TextField("Názov pravidla", text: $rule.name).textFieldStyle(.roundedBorder)
                        Picker("", selection: $rule.accountID) {
                            Text("Všetky účty").tag(String?.none)
                            ForEach(model.settings.accounts) { Text(model.accountTitle($0)).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    section("Keď") {
                        Picker("", selection: $rule.matchAll) {
                            Text("Platia všetky podmienky").tag(true)
                            Text("Platí ktorákoľvek").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        ForEach($rule.conditions) { $condition in
                            conditionRow($condition)
                        }
                        Button { rule.conditions.append(RuleCondition(field: .subject)) } label: {
                            Label("Pridať podmienku", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        Text("Viac možností oddeľte čiarkou: „faktúra, invoice“. Na veľkosti písmen ani diakritike nezáleží.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Potom") {
                        ForEach(Array(rule.actions.enumerated()), id: \.offset) { offset, _ in
                            actionRow(offset)
                        }
                        Button { rule.actions.append(.markRead) } label: {
                            Label("Pridať akciu", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }

                    section("Kedy") {
                        Picker("", selection: Binding(get: { rule.afterDays != nil },
                                                      set: { rule.afterDays = $0 ? (rule.afterDays ?? 7) : nil })) {
                            Text("Hneď po doručení").tag(false)
                            Text("Keď je v Doručenej dlhšie ako…").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        if let days = rule.afterDays {
                            Stepper("\(days) \(days == 1 ? "deň" : days < 5 ? "dni" : "dní")",
                                    value: Binding(get: { days }, set: { rule.afterDays = $0 }), in: 1...365)
                                .fixedSize()
                                .padding(.leading, 20)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                if !isNew {
                    Button("Odstrániť", role: .destructive) {
                        model.settings.rules.removeAll { $0.id == rule.id }
                        dismiss()
                    }
                }
                Spacer()
                Button("Zrušiť") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Uložiť a spustiť na Doručenú") {
                    save()
                    let saved = rule
                    Task { await model.runRuleNow(saved) }
                }
                .disabled(!isValid)
                Button("Uložiť") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
    }

    private func save() {
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            rule.name = rule.conditions.first.map(RuleText.condition)?.capitalizedFirst ?? "Pravidlo"
        }
        if let index = model.settings.rules.firstIndex(where: { $0.id == rule.id }) {
            model.settings.rules[index] = rule
        } else {
            rule.createdAt = Date()
            model.settings.rules.append(rule)
        }
        dismiss()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func conditionRow(_ condition: Binding<RuleCondition>) -> some View {
        HStack {
            Picker("", selection: condition.field) {
                ForEach(RuleCondition.Field.allCases, id: \.self) { Text(RuleText.fieldTitle($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: condition.wrappedValue.field) { _, field in
                let allowed = RuleText.operators(for: field)
                if !allowed.isEmpty && !allowed.contains(condition.wrappedValue.op) { condition.wrappedValue.op = allowed[0] }
            }
            let operators = RuleText.operators(for: condition.wrappedValue.field)
            if operators.count > 1 {
                Picker("", selection: condition.op) {
                    ForEach(operators, id: \.self) { Text(RuleText.operatorTitle($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            } else if let only = operators.first {
                Text(RuleText.operatorTitle(only)).foregroundStyle(.secondary)
            }
            if !condition.wrappedValue.field.needsNoValue {
                TextField(condition.wrappedValue.field == .attachmentSize ? "10" : "text", text: condition.value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
            }
            Button { rule.conditions.removeAll { $0.id == condition.wrappedValue.id } } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(rule.conditions.count == 1)
        }
    }

    private enum ActionKind: String, CaseIterable {
        case archive, markRead, star, tag, moveToFolder, noNotification, trash

        var title: String {
            switch self {
            case .archive: "Archivovať"
            case .markRead: "Označiť ako prečítané"
            case .star: "Označiť hviezdičkou"
            case .tag: "Pridať štítok"
            case .moveToFolder: "Presunúť do priečinka"
            case .noNotification: "Neupozorňovať"
            case .trash: "Presunúť do koša"
            }
        }

        init(_ action: RuleAction) {
            switch action {
            case .archive: self = .archive
            case .markRead: self = .markRead
            case .star: self = .star
            case .tag: self = .tag
            case .moveToFolder: self = .moveToFolder
            case .noNotification: self = .noNotification
            case .trash: self = .trash
            }
        }
    }

    private func actionRow(_ offset: Int) -> some View {
        let action = rule.actions[offset]
        let folders = model.ruleFolders(accountID: rule.accountID)
        return HStack {
            Picker("", selection: Binding(get: { ActionKind(action) }, set: { kind in
                rule.actions[offset] = switch kind {
                case .archive: .archive
                case .markRead: .markRead
                case .star: .star
                case .tag: .tag("")
                case .moveToFolder: .moveToFolder(folders.first?.name ?? "")
                case .noNotification: .noNotification
                case .trash: .trash
                }
            })) {
                ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
            switch action {
            case .tag(let tag):
                TextField("názov štítka", text: Binding(get: { tag }, set: { rule.actions[offset] = .tag($0) }))
                    .textFieldStyle(.roundedBorder)
                Menu("Štítky") {
                    ForEach(model.menuTags, id: \.self) { name in
                        Button(name) { rule.actions[offset] = .tag(name) }
                    }
                }
                .fixedSize()
            case .moveToFolder(let mailbox):
                if folders.isEmpty {
                    Text(rule.accountID == nil ? "Vyberte účet – priečinky sú v každom účte iné." : "Účet nemá vlastné priečinky.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(get: { mailbox }, set: { rule.actions[offset] = .moveToFolder($0) })) {
                        ForEach(folders) { Text($0.path.joined(separator: " / ")).tag($0.name) }
                    }
                    .labelsHidden()
                }
            default:
                Spacer()
            }
            Button { rule.actions.remove(at: offset) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(rule.actions.count == 1)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
