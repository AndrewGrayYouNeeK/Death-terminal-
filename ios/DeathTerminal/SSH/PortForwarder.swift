import Foundation
import Combine
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// Local port forward over an existing SSH connection, like `ssh -L`.
/// Listens on 127.0.0.1:localPort on the device and tunnels each accepted
/// connection to remoteHost:remotePort through a direct-tcpip channel.
///
/// iOS suspends apps in the background, so forwards only carry traffic while
/// Death Terminal is in the foreground (or briefly after switching away).
@MainActor
final class PortForwarder: ObservableObject, Identifiable {
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    nonisolated let id = UUID()
    let rule: PortForwardRule
    private let client: SSHClient
    private var server: Channel?
    @Published private(set) var status: Status = .stopped

    init(rule: PortForwardRule, client: SSHClient) {
        self.rule = rule
        self.client = client
    }

    func start() {
        guard server == nil else { return }
        let client = client
        let rule = rule
        Task {
            do {
                // Listener and its accepted sockets run on the SSH connection's own
                // event loop, so the glue between them never crosses threads.
                let bootstrap = ServerBootstrap(group: client.eventLoop)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .childChannelInitializer { local in
                        PortForwarder.bridge(local: local, client: client, rule: rule)
                    }
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: rule.localPort).get()
                self.server = channel
                self.status = .listening
            } catch {
                self.status = .failed(String(describing: error))
            }
        }
    }

    func stop() {
        let server = server
        self.server = nil
        status = .stopped
        server?.close(promise: nil)
    }

    private nonisolated static func bridge(local: Channel, client: SSHClient, rule: PortForwardRule) -> EventLoopFuture<Void> {
        let originator = local.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
        guard let originator else { return local.eventLoop.makeFailedFuture(ChannelError.inputClosed) }
        let (localGlue, remoteGlue) = GlueHandler.matchedPair()
        let target = SSHChannelType.DirectTCPIP(
            targetHost: rule.remoteHost, targetPort: rule.remotePort, originatorAddress: originator)
        return local.eventLoop.makeFutureWithTask {
            _ = try await client.createDirectTCPIPChannel(using: target) { remote in
                remote.pipeline.addHandler(remoteGlue)
            }
        }.flatMap {
            local.pipeline.addHandler(localGlue)
        }.flatMapError { error in
            local.close(promise: nil)
            return local.eventLoop.makeFailedFuture(error)
        }
    }
}
