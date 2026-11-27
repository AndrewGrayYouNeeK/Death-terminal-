import SwiftUI
import SwiftTerm
import UIKit

struct TerminalScreen: View {
    @ObservedObject var session: SSHSession
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var snippets: SnippetStore
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var knownHosts: KnownHostsStore
    @EnvironmentObject private var prompter: HostKeyPrompter
    @Environment(\.dismiss) private var dismiss

    @State private var showSFTP = false
    @State private var showForwards = false
    @State private var showSnippets = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            SwiftTermView(session: session)
                .ignoresSafeArea(.container, edges: .bottom)
            statusBanner
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSnippets = true } label: { Image(systemName: "text.badge.plus") }
                    .accessibilityLabel("Snippets")
                Menu {
                    Button { showSFTP = true } label: { Label("Files (SFTP)", systemImage: "folder") }
                    Button { showForwards = true } label: { Label("Port forwards", systemImage: "arrow.left.arrow.right") }
                    if session.state == .closed || isFailed {
                        Button { session.connect(hosts: hosts, knownHosts: knownHosts, prompter: prompter) } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive) {
                        sessions.close(session)
                        dismiss()
                    } label: { Label("Disconnect", systemImage: "xmark.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showSFTP) { SFTPBrowserView(session: session) }
        .sheet(isPresented: $showForwards) { ForwardsView(session: session) }
        .sheet(isPresented: $showSnippets) {
            SnippetPicker { snippet in
                session.send(text: snippet.command + (snippet.runImmediately ? "\r" : ""))
                showSnippets = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.state {
        case .connecting:
            Label("Connecting to \(session.host.address)…", systemImage: "bolt.horizontal")
                .font(Theme.mono(12)).padding(8)
                .background(Theme.panel, in: Capsule()).padding(.top, 8)
        case .failed(let msg):
            Text(msg).font(Theme.mono(12)).foregroundStyle(Theme.danger).padding(8)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8)).padding(8)
        default:
            EmptyView()
        }
    }
}

/// SwiftTerm's UIKit terminal, wired to an SSHSession.
struct SwiftTermView: UIViewRepresentable {
    let session: SSHSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.nativeBackgroundColor = Theme.uiBackground
        tv.nativeForegroundColor = Theme.uiText
        tv.caretColor = Theme.uiGreen
        tv.selectedTextBackgroundColor = Theme.uiGreen.withAlphaComponent(0.35)
        tv.keyboardAppearance = .dark
        session.onOutput = { [weak tv] bytes in tv?.feed(byteArray: bytes) }
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.session.onOutput = nil
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        init(session: SSHSession) { self.session = session }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { session.setTitle(title) }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { session.send(bytes) }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
        }
        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
