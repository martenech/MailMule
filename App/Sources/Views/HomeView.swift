import MailmuleKit
import SwiftUI

/// Cards on the Prehľad page, like the widgets on Pathfinder's Home.
enum HomeWidget: String, CaseIterable, Identifiable, Codable {
    case unread, calendar, waiting, returning, scheduled, attachments, inbox, notes

    var id: String { rawValue }

    static let defaultOrder: [HomeWidget] = [.unread, .calendar, .waiting, .returning, .attachments, .inbox, .scheduled, .notes]

    var title: String {
        switch self {
        case .unread: "Neprečítané"
        case .calendar: "Dnes v kalendári"
        case .waiting: "Bez odpovede"
        case .returning: "Vracia sa dnes"
        case .scheduled: "Naplánované na odoslanie"
        case .attachments: "Nové prílohy"
        case .inbox: "Doručená pošta"
        case .notes: "Poznámky"
        }
    }

    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .calendar: "calendar"
        case .waiting: "hourglass"
        case .returning: "clock.arrow.circlepath"
        case .scheduled: "calendar.badge.clock"
        case .attachments: "paperclip"
        case .inbox: "tray.2"
        case .notes: "note.text"
        }
    }

    var summary: String {
        switch self {
        case .unread: "Neprečítané od VIP odosielateľov (alebo všetky)."
        case .calendar: "Stretnutia z pozvánok dnes a zajtra."
        case .waiting: "Vlákna, na ktoré čakáte odpoveď."
        case .returning: "Odložené maily, ktoré sa dnes vrátia."
        case .scheduled: "Správy, ktoré sa odošlú neskôr."
        case .attachments: "Posledné prílohy s náhľadom."
        case .inbox: "Neprečítané v každom účte."
        case .notes: "Rýchly zápisník."
        }
    }

    /// For distributing cards into columns (the shortest column gets the next one).
    var estimatedHeight: CGFloat {
        switch self {
        case .unread, .attachments: 300
        case .calendar, .waiting: 240
        case .returning, .scheduled, .inbox: 170
        case .notes: 220
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var data = HomeData()
    @State private var width: CGFloat = 900
    @State private var showCustomize = false
    @State private var showGallery = false

    private var widgets: [HomeWidget] {
        model.settings.homeWidgets.compactMap(HomeWidget.init(rawValue:))
    }

    private var columnCount: Int { width >= 1150 ? 3 : width >= 720 ? 2 : 1 }

    private func columns() -> [[HomeWidget]] {
        var columns = Array(repeating: [HomeWidget](), count: columnCount)
        var heights = Array(repeating: CGFloat(0), count: columnCount)
        for widget in widgets {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(widget)
            heights[shortest] += widget.estimatedHeight
        }
        return columns
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                let hidden = HomeWidget.allCases.filter { !widgets.contains($0) }
                let columns = columns()
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        VStack(spacing: 14) {
                            ForEach(column) { widget in
                                HomeCard(widget: widget) { content(widget) } accessory: { accessory(widget) }
                            }
                            if index == columns.count - 1 && !hidden.isEmpty { addWidgetTile }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                if widgets.isEmpty {
                    ContentUnavailableView {
                        Label("Prehľad je prázdny", systemImage: "square.dashed")
                    } description: {
                        Text("Pridajte karty, ktoré chcete vidieť.")
                    } actions: {
                        Button("Pridať kartu…") { showGallery = true }
                    }
                }
                footer
            }
            .padding(20)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .popover(isPresented: $showGallery, arrowEdge: .top) { gallery }
        .task(id: reloadKey) { data = await model.homeData() }
        .navigationTitle("Prehľad")
    }

    /// Reload when mail, reminders or drafts change.
    private var reloadKey: String {
        "\(model.calendarRevision)-\(model.settings.calendarConnected)-\(model.inboxUnread)-\(model.followUps.count)-\(model.snoozes.count)-\(model.drafts.count)-\(model.threads.first?.id ?? "")"
    }

    // MARK: Header

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let word = switch hour {
        case 5..<10: "Dobré ráno"
        case 10..<18: "Dobrý deň"
        case 18..<23: "Dobrý večer"
        default: "Dobrú noc"
        }
        let name = model.settings.homeName.isEmpty
            ? (model.settings.accounts.first?.name.split(separator: " ").first.map(String.init) ?? "")
            : model.settings.homeName
        return name.isEmpty ? word : "\(word), \(name)"
    }

    private var subtitle: String {
        var parts = [Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst]
        let unread = model.inboxUnread
        parts.append(unread == 0 ? "Doručená pošta je prečítaná" : "\(unread) \(unread == 1 ? "neprečítané vlákno" : unread < 5 ? "neprečítané vlákna" : "neprečítaných vlákien")")
        let today = data.events.filter { Calendar.current.isDateInToday($0.start) }.count
        if today > 0 { parts.append("\(today) \(today == 1 ? "stretnutie" : today < 5 ? "stretnutia" : "stretnutí") dnes") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color.themeAccent.opacity(0.10), Color.themeAccent.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(Color.themeAccent.opacity(0.18))
                        .offset(x: -24, y: 30)
                }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.settings.homeGreeting ? greeting : "Prehľad")
                        .font(.system(size: 30, weight: .bold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                if model.settings.homeQuote {
                    Text("„\(Self.quoteOfTheDay)“")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .padding(.trailing, 150)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            Button { showCustomize = true } label: {
                Label("Prispôsobiť", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .padding(14)
            .popover(isPresented: $showCustomize, arrowEdge: .bottom) { customize }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private static let quotes = [
        "Prázdna schránka nie je cieľ, je to pokoj.",
        "Čo sa dá vybaviť za dve minúty, vybav hneď.",
        "Odpovedz raz, ale poriadne.",
        "Najlepší e-mail je ten, ktorý nemusíš napísať.",
        "Najprv dôležité, potom naliehavé.",
        "Jedna vec naraz.",
        "Dobrá správa je krátka správa.",
        "Archív je tvoj priateľ.",
        "Neodkladaj, rozhodni.",
        "Menej mailov, viac práce.",
    ]

    private static var quoteOfTheDay: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return quotes[day % quotes.count]
    }

    // MARK: Cards

    @ViewBuilder
    private func content(_ widget: HomeWidget) -> some View {
        switch widget {
        case .unread:
            if data.unread.isEmpty {
                empty(data.vipOnly ? "Od VIP odosielateľov nič neprečítané." : "Všetko prečítané. 🎉")
            } else {
                ForEach(data.unread.prefix(6)) { thread in
                    threadRow(thread, trailing: ThreadRow.shortDate(thread.date))
                }
            }
        case .calendar:
            if data.events.isEmpty {
                empty(model.settings.calendarConnected ? "Dnes a zajtra nemáte žiadne udalosti." : "Dnes a zajtra žiadne stretnutia z pozvánok.")
            } else {
                ForEach(data.events) { event in eventRow(event) }
            }
            if !model.settings.calendarConnected {
                Button {
                    model.settingsCategory = .calendar
                    model.settingsOpenRequest += 1
                } label: {
                    Label("Pripojiť Kalendár z Macu…", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        case .waiting:
            if data.waiting.isEmpty {
                empty("Na žiadnu odpoveď nečakáte.")
            } else {
                ForEach(data.waiting.prefix(6), id: \.thread.id) { item in
                    threadRow(item.thread, trailing: item.followUp.fired ? "Bez odpovede" : "do \(item.followUp.due.formatted(.dateTime.day().month(.defaultDigits)))",
                              trailingColor: item.followUp.fired ? .orange : .secondary)
                }
            }
        case .returning:
            if data.returning.isEmpty {
                empty("Dnes sa nič odložené nevracia.")
            } else {
                ForEach(data.returning, id: \.thread.id) { item in
                    threadRow(item.thread, trailing: item.date.formatted(date: .omitted, time: .shortened))
                }
            }
        case .scheduled:
            if data.scheduled.isEmpty {
                empty("Nič naplánované.")
            } else {
                ForEach(data.scheduled.prefix(5)) { draft in
                    Button { model.openDraft(draft) } label: {
                        HStack {
                            Image(systemName: "paperplane").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(draft.subject.isEmpty ? "(bez predmetu)" : draft.subject).lineLimit(1)
                                Text(draft.to).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(draft.scheduledAt.map { SnoozeOption.describe($0) } ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .attachments:
            if data.attachments.isEmpty {
                empty("Žiadne prílohy.")
            } else {
                ForEach(data.attachments.prefix(6)) { item in
                    Button { model.previewAttachments(in: item.message, startingAt: item.filename) } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (item.filename as NSString).pathExtension) ?? .data))
                                .resizable().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.filename).lineLimit(1).truncationMode(.middle)
                                Text(item.message.from?.displayName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(item.message.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Náhľad")
                }
            }
        case .inbox:
            ForEach(data.inbox, id: \.account.id) { item in
                Button {
                    model.showingHome = false
                    model.accountScope = item.account.id
                    model.filter = .inbox
                } label: {
                    HStack(spacing: 10) {
                        AccountBadge(account: item.account, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.accountTitle(item.account)).lineLimit(1)
                            Text(item.account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.unread == 0 ? "prečítané" : "\(item.unread) neprečítané")
                            .font(.caption)
                            .foregroundStyle(item.unread == 0 ? Color.green : Color.themeAccent)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .notes:
            @Bindable var model = model
            TextEditor(text: $model.settings.homeNotes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if model.settings.homeNotes.isEmpty {
                        Text("Poznámka na dnes…").foregroundStyle(.tertiary).padding(.leading, 11).padding(.top, 6).allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private func accessory(_ widget: HomeWidget) -> some View {
        switch widget {
        case .unread:
            Button("Doručená") { model.showingHome = false; model.filter = .inbox }.buttonStyle(.link).font(.caption)
        case .waiting:
            Button("Všetko") { model.showingHome = false; model.filter = .followUps }.buttonStyle(.link).font(.caption)
        case .attachments:
            Button("Všetky") { model.showingAttachments = true }.buttonStyle(.link).font(.caption)
        default:
            EmptyView()
        }
    }

    private func eventRow(_ event: HomeEvent) -> some View {
        Button {
            if event.calendarItemID != nil { CalendarLink.show(event) } else if let thread = event.threadID { model.openFromHome(thread) }
        } label: {
            HStack(spacing: 10) {
                VStack(spacing: 0) {
                    Text(Calendar.current.isDateInToday(event.start) ? "Dnes" : "Zajtra")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(event.isAllDay ? "celý deň" : event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 64)
                RoundedRectangle(cornerRadius: 1.5).fill(event.color ?? Color.themeAccent).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title.isEmpty ? "Udalosť" : event.title).lineLimit(1)
                        if event.threadID != nil {
                            Image(systemName: "envelope").font(.caption2).foregroundStyle(.secondary).help("Pozvánka v pošte")
                        }
                    }
                    if let subtitle = [event.location, event.calendarTitle].compactMap({ $0 }).first {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let join = event.joinURL {
                    Button("Pripojiť sa") { NSWorkspace.shared.open(join) }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if event.calendarItemID != nil { Button("Zobraziť v Kalendári") { CalendarLink.show(event) } }
            if let thread = event.threadID { Button("Otvoriť pozvánku") { model.openFromHome(thread) } }
        }
    }

    private func threadRow(_ thread: ThreadSummary, trailing: String, trailingColor: Color = .secondary) -> some View {
        let person = counterpart(thread)
        return Button { model.openFromHome(thread.id) } label: {
            HStack(spacing: 10) {
                SenderAvatar(name: person.name, address: person.address, emphasized: thread.isUnread, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.subject.isEmpty ? "(bez predmetu)" : thread.subject).lineLimit(1)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                    Text(person.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(trailing).font(.caption).foregroundStyle(trailingColor)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Who the thread is with: the latest sender, or when that is you (waiting for a reply), the other side.
    private func counterpart(_ thread: ThreadSummary) -> (name: String, address: String) {
        let own = Set(model.settings.accounts.map { $0.email.lowercased() })
        guard own.contains(thread.latestSenderAddress.lowercased()) else { return (thread.latestSender, thread.latestSenderAddress) }
        for (index, address) in thread.participantAddresses.enumerated() where !own.contains(address.lowercased()) {
            return (thread.participants.indices.contains(index) ? thread.participants[index] : address, address)
        }
        return (thread.latestSender, thread.latestSenderAddress)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
    }

    private var addWidgetTile: some View {
        Button { showGallery = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.title)
                Text("Pridať kartu").fontWeight(.medium)
                Text("Vybrať z galérie").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.tertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("Pošta ako súbory, ktoré vlastníš.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            @Bindable var model = model
            Toggle("Otvárať Prehľad po spustení", isOn: $model.settings.openHomeOnLaunch)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .padding(.top, 6)
    }

    // MARK: Popovers

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pridať kartu").font(.headline)
            let hidden = HomeWidget.allCases.filter { !widgets.contains($0) }
            if hidden.isEmpty {
                Text("Všetky karty už sú na Prehľade.").foregroundStyle(.secondary)
            }
            ForEach(hidden) { widget in
                Button {
                    model.settings.homeWidgets.append(widget.rawValue)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: widget.symbol).font(.title3).foregroundStyle(Color.themeAccent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(widget.title).fontWeight(.medium)
                            Text(widget.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var customize: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("Karty").font(.headline)
            ForEach(HomeWidget.allCases) { widget in
                Toggle(isOn: Binding(
                    get: { widgets.contains(widget) },
                    set: { on in
                        model.settings.homeWidgets.removeAll { $0 == widget.rawValue }
                        if on { model.settings.homeWidgets.append(widget.rawValue) }
                    })) {
                    Label(widget.title, systemImage: widget.symbol)
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            Toggle("Pozdrav", isOn: $model.settings.homeGreeting).toggleStyle(.checkbox)
            if model.settings.homeGreeting {
                TextField("Meno v pozdrave", text: $model.settings.homeName).textFieldStyle(.roundedBorder)
            }
            Toggle("Myšlienka dňa", isOn: $model.settings.homeQuote).toggleStyle(.checkbox)
            Text("Poradie kariet zmeníte potiahnutím za nadpis.").font(.caption).foregroundStyle(.secondary)
            Button("Obnoviť predvolené") {
                model.settings.homeWidgets = HomeWidget.defaultOrder.map(\.rawValue)
                model.settings.homeGreeting = true
                model.settings.homeQuote = true
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// A card on Prehľad: accent icon, title, accessory and a menu; drag the title to reorder.
private struct HomeCard<Content: View, Accessory: View>: View {
    @Environment(AppModel.self) private var model
    let widget: HomeWidget
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: widget.symbol).foregroundStyle(Color.themeAccent)
                Text(widget.title).font(.headline)
                Spacer()
                accessory
                Menu {
                    Button("Posunúť vyššie") { move(by: -1) }
                    Button("Posunúť nižšie") { move(by: 1) }
                    Divider()
                    Button("Skryť kartu") { model.settings.homeWidgets.removeAll { $0 == widget.rawValue } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .draggable(widget.rawValue)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? Color.themeAccent : Color.primary.opacity(0.08), lineWidth: targeted ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, raw != widget.rawValue,
                  let from = model.settings.homeWidgets.firstIndex(of: raw) else { return false }
            withAnimation {
                var list = model.settings.homeWidgets
                list.remove(at: from)
                let to = list.firstIndex(of: widget.rawValue) ?? list.endIndex
                list.insert(raw, at: to)
                model.settings.homeWidgets = list
            }
            return true
        } isTargeted: { targeted = $0 }
    }

    private func move(by offset: Int) {
        var list = model.settings.homeWidgets
        guard let index = list.firstIndex(of: widget.rawValue), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        model.settings.homeWidgets = list
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
