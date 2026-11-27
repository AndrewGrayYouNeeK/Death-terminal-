import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "Private key" }
}

/// A saved server. Secrets (password, key material) are never stored here;
/// they live in the iOS Keychain, keyed by `id`.
struct SavedHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var group: String = ""
    var auth: AuthMethod = .password
    var keyID: UUID?
    var forwards: [PortForwardRule] = []

    var displayName: String { label.isEmpty ? "\(username)@\(hostname)" : label }
    var address: String { port == 22 ? hostname : "\(hostname):\(port)" }
    /// Key used for known_hosts, matching OpenSSH's "[host]:port" form.
    var knownHostsKey: String { port == 22 ? hostname : "[\(hostname)]:\(port)" }
}

/// A private key the user imported. Only the name is stored here; the key text
/// and its passphrase live in the Keychain.
struct StoredKey: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: String  // "ed25519" or "rsa"
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    /// Send a newline after the command so it runs right away.
    var runImmediately: Bool = true
}

/// Local port forward: 127.0.0.1:localPort on the phone -> remoteHost:remotePort
/// as seen from the SSH server.
struct PortForwardRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var localPort: Int = 8080
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int = 80
    var summary: String { "localhost:\(localPort) → \(remoteHost):\(remotePort)" }
}

struct KnownHost: Codable, Identifiable, Hashable {
    var id: String { host + " " + keyType }
    var host: String        // "example.com" or "[example.com]:2222"
    var keyType: String     // e.g. "ssh-ed25519"
    var publicKey: String   // full OpenSSH public key line ("type base64")
    var fingerprint: String // "SHA256:..."
    var added = Date()
}
