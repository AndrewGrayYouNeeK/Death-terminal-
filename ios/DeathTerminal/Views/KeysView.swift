import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @EnvironmentObject private var hosts: HostStore
    @State private var showImport = false
    @State private var showGenerate = false
    @State private var shownKey: StoredKey?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(hosts.keys) { key in
                        Button { shownKey = key } label: {
                        HStack {
                            Image(systemName: "key.fill").foregroundStyle(Theme.green)
                            VStack(alignment: .leading) {
                                Text(key.name).font(Theme.mono(14, weight: .semibold))
                                Text(key.kind).font(Theme.mono(12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        }
                    }
                    .onDelete { idx in idx.map { hosts.keys[$0] }.forEach(hosts.deleteKey) }
                } footer: {
                    Text("Private keys and passphrases are stored in the iOS Keychain on this device only. OpenSSH ed25519 keys are recommended. RSA keys only work on servers that still accept the older ssh-rsa (SHA-1) signature.")
                }
            }
            .overlay {
                if hosts.keys.isEmpty { Text("No keys yet").foregroundStyle(.secondary) }
            }
            .dtBackground()
            .navigationTitle("Keychain")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showGenerate = true } label: { Label("Generate ed25519 key", systemImage: "wand.and.stars") }
                        Button { showImport = true } label: { Label("Import private key", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showImport) { KeyImportView() }
            .sheet(item: $shownKey) { key in PublicKeyView(key: key) }
            .alert("Generate ed25519 key", isPresented: $showGenerate) {
                Button("Generate") { shownKey = hosts.generateEd25519(name: "iPhone ed25519") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a new key on this device. Then add its public key to ~/.ssh/authorized_keys on your server.")
            }
        }
    }
}

struct KeyImportView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var passphrase = ""
    @State private var error: String?
    @State private var pickFile = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Private key") {
                    TextEditor(text: $text)
                        .font(Theme.mono(11))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { pickFile = true } label: { Label("Import from Files", systemImage: "doc") }
                    Button { text = UIPasteboard.general.string ?? text } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                }
                SecureField("Passphrase (if encrypted)", text: $passphrase)
                if let error {
                    Text(error).foregroundStyle(Theme.danger).font(.footnote)
                }
            }
            .dtBackground()
            .navigationTitle("Import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(text.isEmpty) }
            }
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let s = try? String(contentsOf: url, encoding: .utf8) {
                    text = s
                    if name.isEmpty { name = url.lastPathComponent }
                }
            }
        }
    }

    private func save() {
        do {
            _ = try hosts.importKey(name: name, text: text, passphrase: passphrase)
            dismiss()
        } catch {
            self.error = "Couldn't read that key: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }
}

struct PublicKeyView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    let key: StoredKey
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let pub = hosts.publicKey(for: key) {
                    Text("Add this line to ~/.ssh/authorized_keys on the server:")
                        .foregroundStyle(Theme.text)
                    Text(pub)
                        .font(Theme.mono(12)).foregroundStyle(Theme.green)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = pub
                            copied = true
                        }
                        .buttonStyle(.borderedProminent)
                        ShareLink(item: pub) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Text("Public key display is available for ed25519 keys. For RSA keys, use the .pub file you already have.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .dtBackground()
            .navigationTitle(key.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
