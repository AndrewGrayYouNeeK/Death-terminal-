import Foundation
import Combine
import Citadel
import NIOCore
import NIOSSH

/// One live SSH connection to a saved host: an interactive PTY shell, plus
/// SFTP and local port forwards that share the same connection.
@MainActor
final class SSHSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    let id = UUID()
    let host: SavedHost
    @Published private(set) var state: State = .connecting
    @Published private(set) var title: String
    @Published private(set) var forwarders: [PortForwarder] = []

    /// Terminal output sink, set by the terminal view.
    var onOutput: ((ArraySlice<UInt8>) -> Void)? {
        didSet { flushBacklog() }
    }

    private(set) var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var shellTask: Task<Void, Never>?
    private var backlog: [UInt8] = []
    private var size = (cols: 80, rows: 24)
    private var sftp: SFTPClient?

    init(host: SavedHost) {
        self.host = host
        self.title = host.displayName
    }

    func connect(hosts: HostStore, knownHosts: KnownHostsStore, prompter: HostKeyPrompter) {
        state = .connecting
        let host = self.host
        shellTask = Task { [weak self] in
            do {
                let auth = try SSHKeys.authMethod(for: host, store: hosts)
                let validator = KnownHostsValidator(hostKey: host.knownHostsKey, store: knownHosts, prompter: prompter)
                var settings = SSHClientSettings(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: { auth },
                    hostKeyValidator: .custom(validator))
                settings.connectTimeout = .seconds(20)
                let client = try await SSHClient.connect(to: settings)
                guard let self else { try? await client.close(); return }
                self.client = client
                client.onDisconnect { [weak self] in
                    Task { @MainActor in self?.markClosed() }
                }
                self.startForwards()
                try await self.runShell(client)
                self.markClosed()
            } catch {
                self?.fail(error)
            }
        }
    }

    private func runShell(_ client: SSHClient) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size.cols,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        try await client.withPTY(request) { inbound, outbound in
            await MainActor.run {
                self.writer = outbound
                self.state = .connected
            }
            for try await chunk in inbound {
                let bytes: [UInt8]
                switch chunk {
                case .stdout(let buf), .stderr(let buf):
                    bytes = Array(buf.readableBytesView)
                }
                await MainActor.run { self.emit(bytes) }
            }
        }
    }

    private func emit(_ bytes: [UInt8]) {
        if let onOutput { onOutput(bytes[...]) } else { backlog.append(contentsOf: bytes) }
    }

    private func flushBacklog() {
        guard let onOutput, !backlog.isEmpty else { return }
        onOutput(backlog[...])
        backlog.removeAll()
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        state = .failed(message)
        emit(Array("\r\n\u{1b}[31m[connection failed: \(message)]\u{1b}[0m\r\n".utf8))
        teardown()
    }

    private func markClosed() {
        guard state != .closed else { return }
        if case .failed = state { return }
        state = .closed
        emit(Array("\r\n\u{1b}[32m[session closed]\u{1b}[0m\r\n".utf8))
        teardown()
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(bytes: bytes)) }
    }

    func send(text: String) { send(Array(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols, rows) != size else { return }
        size = (cols, rows)
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func setTitle(_ t: String) { if !t.isEmpty { title = t } }

    // MARK: SFTP

    func sftpClient() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        guard let client else { throw SSHKeyError.missingKey }
        let s = try await client.openSFTP()
        sftp = s
        return s
    }

    // MARK: Port forwarding

    private func startForwards() {
        guard let client else { return }
        forwarders = host.forwards.map { PortForwarder(rule: $0, client: client) }
        for f in forwarders { f.start() }
    }

    func restartForward(_ f: PortForwarder) { f.start() }

    // MARK: Close

    func disconnect() {
        shellTask?.cancel()
        let client = client
        Task { try? await client?.close() }
        markClosed()
    }

    private func teardown() {
        for f in forwarders { f.stop() }
        let sftp = sftp
        self.sftp = nil
        writer = nil
        Task { try? await sftp?.close() }
    }
}

/// All open sessions (the app supports several at once, like tabs).
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [SSHSession] = []

    func open(_ host: SavedHost, hosts: HostStore, knownHosts: KnownHostsStore, prompter: HostKeyPrompter) -> SSHSession {
        let s = SSHSession(host: host)
        sessions.append(s)
        s.connect(hosts: hosts, knownHosts: knownHosts, prompter: prompter)
        return s
    }

    func close(_ s: SSHSession) {
        s.disconnect()
        sessions.removeAll { $0.id == s.id }
    }
}
