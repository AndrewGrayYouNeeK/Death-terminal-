import SwiftUI

@main
struct DeathTerminalApp: App {
    @StateObject private var hosts = HostStore()
    @StateObject private var snippets = SnippetStore()
    @StateObject private var knownHosts = KnownHostsStore()
    @StateObject private var sessions = SessionManager()
    @StateObject private var hostKeyPrompter = HostKeyPrompter()

    var body: some Scene {
        WindowGroup {
            // Every screen sits behind AuthGate, so a required sign-in can be
            // added there without touching the rest of the app.
            AuthGate {
                RootView()
            }
            .environmentObject(hosts)
            .environmentObject(snippets)
            .environmentObject(knownHosts)
            .environmentObject(sessions)
            .environmentObject(hostKeyPrompter)
            .preferredColorScheme(.dark)
            .tint(Theme.green)
        }
    }
}
