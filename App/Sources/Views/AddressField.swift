import MailmuleKit
import SwiftUI

/// To/Cc field with autocomplete: suggestions for the address being typed (after the last comma);
/// ↑↓ choose, Enter or Tab completes, Esc closes the list.
struct AddressField: View {
    @Environment(AppModel.self) private var model
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<ComposeField?>.Binding
    let field: ComposeField
    @State private var selection = 0
    @State private var dismissed = false

    /// The address currently being typed.
    private var token: String {
        String(text.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Addresses already in the field, so they are not suggested again.
    private var entered: Set<String> {
        Set(AddressParser.parseList(text).map { $0.address.lowercased() })
    }

    private var suggestions: [AddressBook.Candidate] {
        guard focus.wrappedValue == field, !dismissed, !token.isEmpty, !token.contains("<") else { return [] }
        return model.addressBook.suggestions(for: token, excluding: entered)
    }

    var body: some View {
        let suggestions = self.suggestions
        TextField(placeholder, text: $text)
            .focused(focus, equals: field)
            .onChange(of: text) {
                selection = 0
                dismissed = false
            }
            .onKeyPress(.downArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                selection = min(selection + 1, suggestions.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                selection = max(selection - 1, 0)
                return .handled
            }
            .onKeyPress(.return) { accept(suggestions) }
            .onKeyPress(.tab) { accept(suggestions) }
            .onKeyPress(.escape) {
                guard !suggestions.isEmpty else { return .ignored }
                dismissed = true
                return .handled
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty {
                    list(suggestions)
                        .offset(y: 24)
                }
            }
    }

    private func accept(_ suggestions: [AddressBook.Candidate]) -> KeyPress.Result {
        guard suggestions.indices.contains(selection) else { return .ignored }
        complete(with: suggestions[selection])
        return .handled
    }

    /// Replaces the typed part with the full address and starts the next one.
    private func complete(with candidate: AddressBook.Candidate) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        parts.removeLast()
        let before = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        text = (before + [candidate.fieldValue]).joined(separator: ", ") + ", "
    }

    private func list(_ suggestions: [AddressBook.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { offset, candidate in
                Button {
                    complete(with: candidate)
                } label: {
                    HStack(spacing: 8) {
                        SenderAvatar(name: candidate.name ?? candidate.address, address: candidate.address, emphasized: false, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(candidate.name ?? candidate.address).lineLimit(1)
                            if candidate.name != nil {
                                Text(candidate.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if candidate.fromContacts {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                                .help("Z Kontaktov")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(offset == selection ? Color.themeAccent.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}
