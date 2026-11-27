// Supabase Auth (email + password) for the Death Terminal iPhone app.
// Plain URLSession + Keychain, no packages. Same Supabase project as the
// desktop app, so one account works on both.
//
// Only the public project URL and anon key live here; they are safe to ship.

import Foundation
import Security

public struct DTSession: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Unix seconds.
    public var expiresAt: Int64
    public var email: String
    public var userId: String
}

public enum DTAuthError: LocalizedError {
    case rejected(String)
    case offline(String)
    case confirmEmail

    public var errorDescription: String? {
        switch self {
        case .rejected(let m): return m
        case .offline(let m): return "Can't reach the sign-in server: \(m)"
        case .confirmEmail: return "We emailed you a confirmation link. Tap it, then log in."
        }
    }
}

@MainActor
public final class DTAuth: ObservableObject {
    public static let projectURL = URL(string: "https://dbtygwwaouallxdtqmmc.supabase.co")!
    public static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRidHlnd3dhb3VhbGx4ZHRxbW1jIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNDMxMDUsImV4cCI6MjEwNzcxOTEwNX0.lQ88H1sWWUyrltzYCUMAyYvsVam6QBVHltFD-uFiv9k"

    @Published public private(set) var session: DTSession?

    public init() {
        session = Keychain.load()
    }

    public var isSignedIn: Bool { session != nil }

    /// Call on launch / foreground. Refreshes a near-expiry token; keeps the
    /// cached session when offline; signs out only if the server rejects it.
    public func restore() async {
        guard let s = session else { return }
        if s.expiresAt - Int64(Date().timeIntervalSince1970) > 120 { return }
        do {
            var fresh = try await token(grant: "refresh_token", body: ["refresh_token": s.refreshToken])
            if fresh.email.isEmpty { fresh.email = s.email }
            if fresh.userId.isEmpty { fresh.userId = s.userId }
            store(fresh)
        } catch DTAuthError.offline {
            // Offline: keep using the cached session.
        } catch {
            store(nil)
        }
    }

    public func logIn(email: String, password: String) async throws {
        store(try await token(grant: "password", body: ["email": email, "password": password]))
    }

    /// Throws `.confirmEmail` when the project requires email confirmation.
    public func signUp(email: String, password: String) async throws {
        let (status, json) = try await post("/auth/v1/signup", ["email": email, "password": password])
        guard status < 400 else { throw DTAuthError.rejected(Self.message(json)) }
        if let s = Self.parse(json) { store(s) } else { throw DTAuthError.confirmEmail }
    }

    public func resetPassword(email: String) async throws {
        let (status, json) = try await post("/auth/v1/recover", ["email": email])
        guard status < 400 else { throw DTAuthError.rejected(Self.message(json)) }
    }

    public func signOut() async {
        if let s = session { _ = try? await post("/auth/v1/logout", nil, bearer: s.accessToken) }
        store(nil)
    }

    // MARK: - HTTP

    private func token(grant: String, body: [String: String]) async throws -> DTSession {
        let (status, json) = try await post("/auth/v1/token?grant_type=\(grant)", body)
        if status >= 500 { throw DTAuthError.offline("server error \(status)") }
        guard status < 400 else { throw DTAuthError.rejected(Self.message(json)) }
        guard let s = Self.parse(json) else { throw DTAuthError.rejected("Unexpected reply from the sign-in server.") }
        return s
    }

    private func post(_ path: String, _ body: [String: String]?, bearer: String? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: Self.projectURL.absoluteString + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (status, json)
        } catch {
            throw DTAuthError.offline(error.localizedDescription)
        }
    }

    static func parse(_ j: [String: Any]) -> DTSession? {
        guard let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        let expiresAt = (j["expires_at"] as? NSNumber)?.int64Value ?? now + ((j["expires_in"] as? NSNumber)?.int64Value ?? 3600)
        let user = j["user"] as? [String: Any]
        return DTSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                         email: user?["email"] as? String ?? "", userId: user?["id"] as? String ?? "")
    }

    static func message(_ j: [String: Any]) -> String {
        switch j["error_code"] as? String {
        case "invalid_credentials": return "Wrong email or password."
        case "email_not_confirmed": return "Email not confirmed yet. Tap the link we emailed you, then log in."
        case "user_already_exists": return "An account with that email already exists. Log in instead."
        case "over_email_send_rate_limit": return "Too many emails sent. Wait a minute and try again."
        default: break
        }
        return (j["msg"] ?? j["error_description"] ?? j["message"] ?? j["error"]) as? String ?? "Sign-in failed."
    }

    private func store(_ s: DTSession?) {
        session = s
        if let s { Keychain.save(s) } else { Keychain.clear() }
    }
}

/// The session in the iOS Keychain (this device only, after first unlock).
enum Keychain {
    static let service = "com.github.andrewgrayyouneek.deathterminal.auth"
    static let account = "session"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ s: DTSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> DTSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(DTSession.self, from: data)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
