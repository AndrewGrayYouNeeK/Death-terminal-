import Foundation
import Citadel
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum SSHKeyError: LocalizedError {
    case unsupported(String)
    case missingKey
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .unsupported(let t): return "Unsupported key type \(t). Use an OpenSSH ed25519 or RSA key."
        case .missingKey: return "This host has no private key selected."
        case .missingPassword: return "No password saved for this host."
        }
    }
}

enum SSHKeys {
    /// Returns "ed25519" or "rsa" for an OpenSSH private key (-----BEGIN OPENSSH PRIVATE KEY-----).
    static func detectKind(_ text: String) throws -> String {
        let type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        switch type {
        case .ed25519: return "ed25519"
        case .rsa: return "rsa"
        default: throw SSHKeyError.unsupported(type.description)
        }
    }

    static func authMethod(username: String, keyText: String, passphrase: String, kind: String) throws -> SSHAuthenticationMethod {
        let decryption = passphrase.isEmpty ? nil : passphrase.data(using: .utf8)
        switch kind {
        case "ed25519":
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryption)
            return .ed25519(username: username, privateKey: key)
        case "rsa":
            let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryption)
            return .rsa(username: username, privateKey: key)
        default:
            throw SSHKeyError.unsupported(kind)
        }
    }

    /// Builds the auth method for a saved host from Keychain secrets.
    @MainActor
    static func authMethod(for host: SavedHost, store: HostStore) throws -> SSHAuthenticationMethod {
        switch host.auth {
        case .password:
            guard let pw = store.password(for: host) else { throw SSHKeyError.missingPassword }
            return .passwordBased(username: host.username, password: pw)
        case .key:
            guard let key = store.key(host.keyID), let text = Keychain.get(Keychain.keyText(key.id)) else {
                throw SSHKeyError.missingKey
            }
            let pass = Keychain.get(Keychain.keyPassphrase(key.id)) ?? ""
            return try authMethod(username: host.username, keyText: text, passphrase: pass, kind: key.kind)
        }
    }
}
