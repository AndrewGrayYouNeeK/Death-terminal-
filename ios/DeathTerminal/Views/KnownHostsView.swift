import SwiftUI

struct KnownHostsView: View {
    @EnvironmentObject private var store: KnownHostsStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.entries) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.host).font(Theme.mono(14, weight: .semibold))
                            Text(e.keyType).font(Theme.mono(11)).foregroundStyle(.secondary)
                            Text(e.fingerprint).font(Theme.mono(11)).foregroundStyle(Theme.green).textSelection(.enabled)
                        }
                    }
                    .onDelete { idx in idx.map { store.entries[$0] }.forEach(store.remove) }
                } footer: {
                    Text("Host keys you've trusted. You're asked to confirm the fingerprint the first time you connect, and warned if it ever changes.")
                }
            }
            .overlay {
                if store.entries.isEmpty { Text("No trusted hosts yet").foregroundStyle(.secondary) }
            }
            .dtBackground()
            .navigationTitle("Known Hosts")
        }
    }
}
