import Foundation
import Combine
import NIOCore
import NIOSSH

/// What the user is being asked about when a host key is new or has changed.
struct HostKeyChallenge: Identifiable {
    let id = UUID()
    let host: String
    let keyType: String
    let fingerprint: String
    let changedFrom: String?
}

/// Shows the fingerprint prompt and waits for the user's answer.
@MainActor
final class HostKeyPrompter: ObservableObject {
    @Published var challenge: HostKeyChallenge?
    private var continuation: CheckedContinuation<Bool, Never>?

    func ask(_ challenge: HostKeyChallenge) async -> Bool {
        // Only one prompt at a time; refuse a second concurrent one.
        if continuation != nil { return false }
        return await withCheckedContinuation { cont in
            continuation = cont
            self.challenge = challenge
        }
    }

    func answer(_ trust: Bool) {
        challenge = nil
        continuation?.resume(returning: trust)
        continuation = nil
    }
}

struct HostKeyRejected: LocalizedError {
    var errorDescription: String? { "Host key not trusted. Connection cancelled." }
}

/// Citadel host-key delegate backed by our known_hosts store.
final class KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate {
    let hostKey: String
    let store: KnownHostsStore
    let prompter: HostKeyPrompter

    init(hostKey: String, store: KnownHostsStore, prompter: HostKeyPrompter) {
        self.hostKey = hostKey
        self.store = store
        self.prompter = prompter
    }

    func validateHostKey(hostKey key: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: key)
        let host = hostKey
        let store = store
        let prompter = prompter
        Task { @MainActor in
            let result = store.check(host: host, publicKey: openSSH)
            if result == .trusted {
                validationCompletePromise.succeed(())
                return
            }
            var changedFrom: String?
            if case .changed(let old) = result { changedFrom = old }
            let type = openSSH.split(separator: " ").first.map(String.init) ?? "unknown"
            let ok = await prompter.ask(HostKeyChallenge(
                host: host, keyType: type,
                fingerprint: Fingerprint.sha256(openSSHKey: openSSH),
                changedFrom: changedFrom))
            if ok {
                store.trust(host: host, publicKey: openSSH)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejected())
            }
        }
    }
}

