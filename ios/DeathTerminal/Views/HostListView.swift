import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var knownHosts: KnownHostsStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var prompter: HostKeyPrompter

    @State private var path: [UUID] = []
    @State private var editing: SavedHost?
    @State private var search = ""

    private var filtered: [SavedHost] {
        guard !search.isEmpty else { return hosts.hosts }
        return hosts.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { BrandHeader() }
                    .listRowBackground(Color.clear)

                if !sessions.sessions.isEmpty {
                    Section("Open sessions") {
                        ForEach(sessions.sessions) { s in
                            NavigationLink(value: s.id) {
                                SessionRow(session: s)
                            }
                        }
                        .onDelete { idx in idx.map { sessions.sessions[$0] }.forEach(sessions.close) }
                    }
                }

                if hosts.hosts.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No hosts yet").font(Theme.mono(15, weight: .semibold))
                            Text("Tap + to add a server. Passwords and keys are kept in the iOS Keychain.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                let grouped = Dictionary(grouping: filtered, by: \.group)
                ForEach(grouped.keys.sorted(), id: \.self) { group in
                    Section(group.isEmpty ? "Hosts" : group) {
                        ForEach(grouped[group] ?? []) { host in
                            Button { connect(host) } label: { HostRow(host: host) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { hosts.delete(host) } label: { Label("Delete", systemImage: "trash") }
                                    Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                                }
                                .contextMenu {
                                    Button { connect(host) } label: { Label("Connect", systemImage: "bolt.fill") }
                                    Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { hosts.delete(host) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search hosts")
            .dtBackground()
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = SavedHost() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add host")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let s = sessions.sessions.first(where: { $0.id == id }) {
                    TerminalScreen(session: s)
                } else {
                    Text("Session closed").foregroundStyle(.secondary)
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host, isNew: hosts.host(host.id) == nil)
            }
        }
    }

    private func connect(_ host: SavedHost) {
        let s = sessions.open(host, hosts: hosts, knownHosts: knownHosts, prompter: prompter)
        path.append(s.id)
    }
}

struct HostRow: View {
    let host: SavedHost
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Theme.green)
                .frame(width: 32, height: 32)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(host.username)@\(host.address)").font(Theme.mono(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !host.forwards.isEmpty {
                Image(systemName: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: host.auth == .key ? "key.fill" : "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: SSHSession
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(session.title).font(Theme.mono(14))
        }
    }
    private var color: Color {
        switch session.state {
        case .connected: return Theme.green
        case .connecting: return .yellow
        case .failed: return Theme.danger
        case .closed: return .gray
        }
    }
}
