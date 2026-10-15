import MailmuleKit
import SwiftUI

/// Tag editor for one thread (`l`): type to filter, Enter toggles the highlighted tag,
/// a new name creates the tag.
struct TagPicker: View {
    @Environment(AppModel.self) private var model
    let threadIDs: [String]
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    /// Tags all selected threads have; toggling adds to all or removes from all.
    private var threadTags: [String] {
        model.commonTags(threadIDs)
    }

    private struct Option: Identifiable {
        var id: String { name }
        let name: String
        let isNew: Bool
    }

    private var options: [Option] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var seenNames = Set<String>()
        let known = (model.menuTags + threadTags).filter { seenNames.insert(Tags.fold($0)).inserted }
        var list = known.filter { trimmed.isEmpty || fold($0).contains(fold(trimmed)) }.map { Option(name: $0, isNew: false) }
        if !trimmed.isEmpty, !known.contains(where: { Tags.fold($0) == Tags.fold(trimmed) }) {
            list.insert(Option(name: trimmed, isNew: true), at: 0)
        }
        return list
    }

    var body: some View {
        let options = self.options
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                TextField(threadIDs.count > 1 ? "Štítok pre \(threadIDs.count) vlákien…" : "Štítok…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .focused($focused)
                    .onSubmit { toggle(options) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, options.count - 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { selection = 0 }
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                            HStack(spacing: 6) {
                                Button {
                                    selection = offset
                                    toggle(options)
                                } label: {
                                    HStack {
                                        let checked = threadTags.contains { Tags.fold($0) == Tags.fold(option.name) }
                                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(checked ? Color.themeAccent : .secondary)
                                        Text(option.isNew ? "Vytvoriť štítok „\(option.name)“" : option.name)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if !option.isNew { TagColorButton(tag: option.name) }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(offset == selection ? Color.themeAccent.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        if options.isEmpty {
                            Text("Napíš názov nového štítka")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                Divider()
                Text("↩ pridať/odobrať · bodka = farba · Esc zavrieť")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
    }

    private func toggle(_ options: [Option]) {
        guard options.indices.contains(selection) else { return }
        let name = options[selection].name
        model.setTag(name, !threadTags.contains { Tags.fold($0) == Tags.fold(name) }, threadIDs: threadIDs)
        query = ""
    }

    private func close() {
        model.tagPickerThreadIDs = nil
    }
}

/// Finder-style tag dots for compact rows: overlapping circles, names in the tooltip.
struct TagDots: View {
    @Environment(AppModel.self) private var model
    let tags: [String]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags, id: \.self) { tag in
                TagDot(color: model.tagColor(tag), size: 10)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .help(tag)
            }
        }
        .accessibilityLabel("Štítky: " + tags.joined(separator: ", "))
    }
}

/// A dot in a Finder tag color; a hollow circle for tags without a color.
struct TagDot: View {
    let color: Int
    var size: CGFloat = 10

    var body: some View {
        if let fill = FinderColor.color(color) {
            Circle().fill(fill).frame(width: size, height: size)
        } else {
            Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: size, height: size)
        }
    }
}

/// Capsule with the tag name in its color; shows × on hover when it can be removed (like Pathfinder).
struct TagPill: View {
    @Environment(AppModel.self) private var model
    let name: String
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let tint = FinderColor.color(model.tagColor(name))
        HStack(spacing: 2) {
            TagColorButton(tag: name, size: 8)
            Text(name).lineLimit(1)
            if let onRemove, hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Odobrať štítok")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .padding(.vertical, 1)
        .background((tint ?? .secondary).opacity(tint == nil ? 0.12 : 0.16), in: Capsule())
        .foregroundStyle(tint ?? .primary)
        .onHover { hovering = $0 }
        .contextMenu {
            Menu("Farba") { TagColorChoices(tag: name) }
            if let onRemove {
                Button("Odobrať štítok", action: onRemove)
            }
        }
    }
}

/// Color dot that opens a popover with Finder's colors for a tag.
struct TagColorButton: View {
    @Environment(AppModel.self) private var model
    let tag: String
    var size: CGFloat = 12
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            TagDot(color: model.tagColor(tag), size: size)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Farba štítka")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TagColorPalette(tag: tag) { showing = false }
        }
    }
}

/// Swatches of Finder's colors; the current one is ringed.
struct TagColorPalette: View {
    @Environment(AppModel.self) private var model
    let tag: String
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Farba štítka „\(tag)“")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 7), spacing: 6) {
                ForEach(FinderColor.menuOrder, id: \.self) { number in
                    Button {
                        model.setTagColor(tag, number)
                        onPick()
                    } label: {
                        TagDot(color: number, size: 18)
                            .padding(2)
                            .overlay(
                                Circle().stroke(Color.primary.opacity(model.tagColor(tag) == number ? 0.7 : 0), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(FinderColor.isFinderColor(number) ? FinderColor.name(number)
                          : "\(FinderColor.name(number)) (vo Finderi \(FinderColor.name(FinderColor.finderNumber(number)).lowercased()))")
                }
            }
            Text(FinderColor.isFinderColor(model.tagColor(tag)) ? " "
                 : "Vo Finderi sa zobrazí ako \(FinderColor.name(FinderColor.finderNumber(model.tagColor(tag))).lowercased()).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// Finder's colors as menu items, with a checkmark on the current one.
struct TagColorChoices: View {
    @Environment(AppModel.self) private var model
    let tag: String

    var body: some View {
        ForEach(FinderColor.menuOrder, id: \.self) { number in
            Button {
                model.setTagColor(tag, number)
            } label: {
                Label {
                    Text(FinderColor.name(number))
                } icon: {
                    Image(systemName: model.tagColor(tag) == number ? "checkmark.circle.fill" : (number == 0 ? "circle" : "circle.fill"))
                        .foregroundStyle(FinderColor.color(number) ?? .secondary)
                }
            }
        }
    }
}
