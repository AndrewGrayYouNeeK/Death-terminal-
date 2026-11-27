import Foundation
enum Keychain {
  nonisolated(unsafe) static var mem: [String: String] = [:]
  static func set(_ value: String, for account: String) { mem[account] = value }
  static func get(_ account: String) -> String? { mem[account] }
  static func delete(_ account: String) { mem[account] = nil }
  static func password(_ host: UUID) -> String { "host-password-\(host.uuidString)" }
  static func keyText(_ key: UUID) -> String { "key-\(key.uuidString)" }
  static func keyPassphrase(_ key: UUID) -> String { "key-passphrase-\(key.uuidString)" }
}
extension URL {
  func startAccessingSecurityScopedResource() -> Bool { false }
  func stopAccessingSecurityScopedResource() {}
}
