import SwiftUI
import UniformTypeIdentifiers

struct SFTPBrowserView: View {
    @StateObject private var model: SFTPBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickUpload = false

    init(session: SSHSession) {
        _model = StateObject(wrappedValue: SFTPBrowserModel(session: session))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.path.isEmpty ? "…" : model.path)
                        .font(Theme.mono(12)).foregroundStyle(Theme.green).lineLimit(2)
                    if model.path != "/" && !model.path.isEmpty {
                        Button { Task { await model.list(model.parent) } } label: {
                            Label("..", systemImage: "arrow.turn.left.up")
                        }
                    }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(Theme.danger).font(.footnote)
                }
                if let status = model.status {
                    HStack { ProgressView(); Text(status).font(.footnote) }
                }
                if let url = model.downloaded {
                    Section("Downloaded") {
                        ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                        Text("Also in Files → On My iPhone → Death Terminal → Downloads")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(model.entries) { e in
                        Button {
                            Task {
                                if e.isDirectory { await model.list(model.child(e.name)) }
                                else { await model.download(e) }
                            }
                        } label: {
                            HStack {
                                Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(e.isDirectory ? Theme.green : .secondary)
                                Text(e.name).font(Theme.mono(14)).foregroundStyle(Theme.text)
                                Spacer()
                                if let size = e.size, !e.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await model.delete(e) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .overlay { if model.loading && model.entries.isEmpty { ProgressView() } }
            .refreshable { await model.list(model.path) }
            .dtBackground()
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { pickUpload = true } label: { Image(systemName: "square.and.arrow.up.on.square") }
                        .accessibilityLabel("Upload")
                        .disabled(model.path.isEmpty)
                }
            }
            .fileImporter(isPresented: $pickUpload, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await model.upload(url) } }
            }
            .task { await model.start() }
        }
    }
}
