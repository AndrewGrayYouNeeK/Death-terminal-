import SwiftUI

struct HostEditView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss

    @State var host: SavedHost
    let isNew: Bool
    @State private var password = ""
    @State private var passwordTouched = false
    @State private var portText = "22"

    init(host: SavedHost, isNew: Bool) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Label (optional)", text: $host.label)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Group (optional)", text: $host.group)
                }
                Section("Authentication") {
                    Picker("Method", selection: $host.auth) {
                        ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if host.auth == .password {
                        SecureField(isNew ? "Password" : "Password (leave blank to keep)", text: $password)
                            .onChange(of: password) { passwordTouched = true }
                    } else {
                        if hosts.keys.isEmpty {
                            Text("Import a key in the Keychain tab first.").foregroundStyle(.secondary)
                        }
                        Picker("Key", selection: $host.keyID) {
                            Text("None").tag(UUID?.none)
                            ForEach(hosts.keys) { Text("\($0.name) (\($0.kind))").tag(Optional($0.id)) }
                        }
                    }
                }
                Section {
                    ForEach($host.forwards) { $rule in
                        ForwardRuleEditor(rule: $rule)
                    }
                    .onDelete { host.forwards.remove(atOffsets: $0) }
                    Button { host.forwards.append(PortForwardRule()) } label: {
                        Label("Add local forward", systemImage: "plus")
                    }
                } header: {
                    Text("Port forwarding")
                } footer: {
                    Text("Like ssh -L. Starts when you connect. Open http://localhost:<local port> on this device while the app is in the foreground.")
                }
            }
            .dtBackground()
            .navigationTitle(isNew ? "New host" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(host.hostname.isEmpty || host.username.isEmpty)
                }
            }
        }
    }

    private func save() {
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.port = Int(portText) ?? 22
        let pw: String? = (host.auth == .password && (isNew || passwordTouched) && !password.isEmpty) ? password : nil
        hosts.save(host, password: pw)
        dismiss()
    }
}

struct ForwardRuleEditor: View {
    @Binding var rule: PortForwardRule
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Local").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                TextField("8080", value: $rule.localPort, format: .number.grouping(.never)).keyboardType(.numberPad)
            }
            HStack {
                Text("Remote").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                TextField("127.0.0.1", text: $rule.remoteHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(":")
                TextField("80", value: $rule.remotePort, format: .number.grouping(.never))
                    .keyboardType(.numberPad).frame(width: 70)
            }
        }
        .font(Theme.mono(14))
    }
}
