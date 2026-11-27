import SwiftUI

struct RootView: View {
    @EnvironmentObject private var prompter: HostKeyPrompter

    var body: some View {
        TabView {
            HostListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
            SnippetsView()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            KeysView()
                .tabItem { Label("Keychain", systemImage: "key.horizontal") }
            KnownHostsView()
                .tabItem { Label("Known Hosts", systemImage: "checkmark.shield") }
        }
        .sheet(item: $prompter.challenge) { challenge in
            HostKeyPromptView(challenge: challenge) { prompter.answer($0) }
        }
    }
}

/// Logo + name, used as a header.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: Theme.green.opacity(0.6), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("YouNeeK Death Terminal").font(Theme.mono(16, weight: .bold)).foregroundStyle(Theme.green)
                Text("ssh · sftp · tunnels").font(Theme.mono(12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
