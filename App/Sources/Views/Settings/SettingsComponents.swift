import SwiftUI

/// A settings page: icon, title and subtitle, then cards.
struct SettingsPage<Content: View>: View {
    let category: SettingsCategory
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Color.themeAccent)
                        .frame(width: 60, height: 60)
                        .background(Color.themeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                            .font(.system(size: 26, weight: .bold))
                        Text(category.subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A rounded card with a title and an optional description.
struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String?
    var subtitle: String?
    var tint: Color?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, tint: Color? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    accessory
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? Color(nsColor: .controlBackgroundColor)).opacity(tint == nil ? 1 : 0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.3)))
    }
}

/// One line of a card: title and description on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, symbol: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, 3)
    }
}

/// A row with a switch.
struct SettingsToggle: View {
    let title: String
    var detail: String?
    var symbol: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, symbol: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail, symbol: symbol) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// Rows separated by thin lines.
struct SettingsRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { offset, subview in
                    if offset > 0 { Divider() }
                    subview
                }
            }
        }
    }
}

/// Removable chips for lists of addresses (VIP senders, exceptions) with a field to add one.
struct AddressChips: View {
    @Binding var entries: [String]
    var placeholder = "adresa alebo @domena.sk"
    @State private var newEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !entries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(entries, id: \.self) { entry in
                        HStack(spacing: 5) {
                            Image(systemName: entry.hasPrefix("@") || entry.hasPrefix("*") ? "globe" : "person")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(entry).font(.system(size: 12))
                            Button { entries.removeAll { $0 == entry } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Pridať", action: add)
                    .disabled(Self.normalize(newEntry) == nil)
            }
        }
    }

    private func add() {
        guard let entry = Self.normalize(newEntry), !entries.contains(entry) else { return }
        entries.append(entry)
        newEntry = ""
    }

    /// `Jan@Firma.sk` → `jan@firma.sk`; `firma.sk`, `*.firma.sk` and `@firma.sk` → `@firma.sk`.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("*.") { value = "@" + value.dropFirst(2) }
        guard !value.isEmpty, value.contains(".") else { return nil }
        if value.contains("@") { return value.hasPrefix("@") || value.split(separator: "@").count == 2 ? value : nil }
        return "@" + value
    }
}

extension AppSettings {
    /// Whether the address matches an entry list of addresses and "@domain" entries (subdomains included).
    static func matches(_ address: String?, _ entries: [String]) -> Bool {
        guard let address = address?.lowercased(), let domain = address.split(separator: "@").last.map(String.init) else { return false }
        return entries.contains { entry in
            if entry.hasPrefix("@") {
                let suffix = String(entry.dropFirst())
                return domain == suffix || domain.hasSuffix("." + suffix)
            }
            return entry == address
        }
    }
}

/// Wraps chips onto several lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
