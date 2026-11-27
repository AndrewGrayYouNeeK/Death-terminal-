import SwiftUI

struct ForwardsView: View {
    @ObservedObject var session: SSHSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.forwarders) { f in
                        ForwarderRow(forwarder: f) { session.restartForward(f) }
                    }
                } footer: {
                    Text("Add or change forwards by editing the host, then reconnect. Traffic flows while Death Terminal is in the foreground.")
                }
            }
            .overlay {
                if session.forwarders.isEmpty {
                    Text(session.state == .connected ? "No forwards for this host" : "Connect first")
                        .foregroundStyle(.secondary)
                }
            }
            .dtBackground()
            .navigationTitle("Port forwards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ForwarderRow: View {
    @ObservedObject var forwarder: PortForwarder
    let restart: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(forwarder.rule.summary).font(Theme.mono(13))
                switch forwarder.status {
                case .listening: Text("listening").font(.caption).foregroundStyle(Theme.green)
                case .stopped: Text("stopped").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            Spacer()
            if forwarder.status != .listening {
                Button("Start", action: restart).buttonStyle(.bordered)
            }
        }
    }
}
