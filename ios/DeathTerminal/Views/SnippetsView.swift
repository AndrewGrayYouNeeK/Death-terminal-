import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject private var store: SnippetStore
    @State private var editing: Snippet?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.snippets) { s in
                    Button { editing = s } label: { SnippetRow(snippet: s) }
                }
                .onDelete { store.snippets.remove(atOffsets: $0) }
                .onMove { store.snippets.move(fromOffsets: $0, toOffset: $1) }
            }
            .dtBackground()
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Snippet(name: "", command: "") } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { s in SnippetEditor(snippet: s) }
        }
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snippet.name.isEmpty ? snippet.command : snippet.name)
                .font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(snippet.command).font(Theme.mono(12)).foregroundStyle(Theme.green).lineLimit(2)
        }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject private var store: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $snippet.name)
                TextField("Command", text: $snippet.command, axis: .vertical)
                    .font(Theme.mono(14))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Run immediately (send Enter)", isOn: $snippet.runImmediately)
            }
            .dtBackground()
            .navigationTitle("Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.upsert(snippet); dismiss() }.disabled(snippet.command.isEmpty)
                }
            }
        }
    }
}

/// Shown from a terminal: tap a snippet to send it.
struct SnippetPicker: View {
    @EnvironmentObject private var store: SnippetStore
    let onPick: (Snippet) -> Void

    var body: some View {
        NavigationStack {
            List(store.snippets) { s in
                Button { onPick(s) } label: { SnippetRow(snippet: s) }
            }
            .overlay {
                if store.snippets.isEmpty {
                    Text("Add snippets in the Snippets tab.").foregroundStyle(.secondary)
                }
            }
            .dtBackground()
            .navigationTitle("Send snippet")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
