import Foundation
import Combine
import Citadel
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Saves a Codable value as JSON in Application Support.
struct JSONFile<T: Codable> {
    let name: String

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SavedHost] = []
    @Published private(set) var keys: [StoredKey] = []
    private let hostFile = JSONFile<[SavedHost]>(name: "hosts.json")
    private let keyFile = JSONFile<[StoredKey]>(name: "keys.json")

    init() {
        hosts = hostFile.load() ?? []
        keys = keyFile.load() ?? []
    }

    var groups: [String] {
        Array(Set(hosts.map(\.group))).sorted()
    }

    func host(_ id: UUID) -> SavedHost? { hosts.first { $0.id == id } }

    func save(_ host: SavedHost, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        if let password {
            if password.isEmpty { Keychain.delete(Keychain.password(host.id)) }
            else { Keychain.set(password, for: Keychain.password(host.id)) }
        }
        hostFile.save(hosts)
    }

    func delete(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        Keychain.delete(Keychain.password(host.id))
        hostFile.save(hosts)
    }

    func password(for host: SavedHost) -> String? { Keychain.get(Keychain.password(host.id)) }

    /// Validates and stores an OpenSSH private key. Returns the new key.
    func importKey(name: String, text: String, passphrase: String) throws -> StoredKey {
        let kind = try SSHKeys.detectKind(text)
        _ = try SSHKeys.authMethod(username: "test", keyText: text, passphrase: passphrase, kind: kind)
        let key = StoredKey(name: name.isEmpty ? "\(kind) key" : name, kind: kind)
        Keychain.set(text, for: Keychain.keyText(key.id))
        if !passphrase.isEmpty { Keychain.set(passphrase, for: Keychain.keyPassphrase(key.id)) }
        keys.append(key)
        keyFile.save(keys)
        return key
    }

    /// Creates a new ed25519 key on the device. Add `publicKey(for:)` to the
    /// server's ~/.ssh/authorized_keys to use it.
    func generateEd25519(name: String) -> StoredKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = StoredKey(name: name.isEmpty ? "iPhone ed25519" : name, kind: "ed25519")
        Keychain.set(privateKey.makeSSHRepresentation(comment: key.name), for: Keychain.keyText(key.id))
        keys.append(key)
        keyFile.save(keys)
        return key
    }

    /// OpenSSH public key line ("ssh-ed25519 AAAA… name") for a stored ed25519
    /// key, ready to paste into ~/.ssh/authorized_keys. Nil for RSA keys
    /// (you already have their .pub file).
    func publicKey(for key: StoredKey) -> String? {
        guard key.kind == "ed25519", let text = Keychain.get(Keychain.keyText(key.id)) else { return nil }
        let pass = Keychain.get(Keychain.keyPassphrase(key.id)).flatMap { $0.data(using: .utf8) }
        guard let k = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: pass) else { return nil }
        func sshString(_ d: Data) -> Data {
            var len = UInt32(d.count).bigEndian
            return Data(bytes: &len, count: 4) + d
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(k.publicKey.rawRepresentation)
        return "ssh-ed25519 " + blob.base64EncodedString() + " " + key.name.replacingOccurrences(of: " ", with: "-")
    }

    func deleteKey(_ key: StoredKey) {
        keys.removeAll { $0.id == key.id }
        Keychain.delete(Keychain.keyText(key.id))
        Keychain.delete(Keychain.keyPassphrase(key.id))
        keyFile.save(keys)
    }

    func key(_ id: UUID?) -> StoredKey? { keys.first { $0.id == id } }
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = [] {
        didSet { file.save(snippets) }
    }
    private let file = JSONFile<[Snippet]>(name: "snippets.json")

    init() {
        snippets = file.load() ?? [
            Snippet(name: "Disk usage", command: "df -h"),
            Snippet(name: "Top processes", command: "top -b -n 1 | head -20"),
            Snippet(name: "Uptime", command: "uptime"),
        ]
    }

    func upsert(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.append(s) }
    }
}

enum HostKeyCheck: Equatable {
    case trusted
    case unknown
    case changed(oldFingerprint: String)
}

@MainActor
final class KnownHostsStore: ObservableObject {
    @Published private(set) var entries: [KnownHost] = []
    private let file = JSONFile<[KnownHost]>(name: "known_hosts.json")

    init() { entries = file.load() ?? [] }

    func check(host: String, publicKey: String) -> HostKeyCheck {
        let type = publicKey.split(separator: " ").first.map(String.init) ?? ""
        guard let existing = entries.first(where: { $0.host == host && $0.keyType == type }) else {
            return .unknown
        }
        return existing.publicKey == publicKey ? .trusted : .changed(oldFingerprint: existing.fingerprint)
    }

    func trust(host: String, publicKey: String) {
        let type = publicKey.split(separator: " ").first.map(String.init) ?? ""
        entries.removeAll { $0.host == host && $0.keyType == type }
        entries.append(KnownHost(host: host, keyType: type, publicKey: publicKey,
                                 fingerprint: Fingerprint.sha256(openSSHKey: publicKey)))
        file.save(entries)
    }

    func remove(_ entry: KnownHost) {
        entries.removeAll { $0.id == entry.id }
        file.save(entries)
    }
}

enum Fingerprint {
    /// OpenSSH-style "SHA256:<base64 without padding>" of the key blob.
    static func sha256(openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}
