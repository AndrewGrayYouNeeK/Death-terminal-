@testable import Core
import Foundation

func wait(_ what: String, timeout: Double = 15, _ cond: @MainActor () -> Bool) async throws {
  let end = Date().addingTimeInterval(timeout)
  while !(await MainActor.run(body: cond)) {
    if Date() > end { print("FAIL timeout:", what); exit(1) }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  print("ok:", what)
}

setvbuf(stdout, nil, _IONBF, 0)
@MainActor func run() async throws {
  let env = ProcessInfo.processInfo.environment
  let dir = env["DT_SSH_DIR"] ?? "/workspace/sshtest"
  let user = env["DT_USER"] ?? "box"
  let hosts = HostStore(), known = KnownHostsStore(), prompter = HostKeyPrompter(), mgr = SessionManager()
  for e in known.entries { known.remove(e) }
  var prompts = 0
  Task { @MainActor in
    while true {
      if prompter.challenge != nil { prompts += 1; print("prompt:", prompter.challenge!.fingerprint, "changed:", prompter.challenge!.changedFrom ?? "-"); prompter.answer(true) }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
  let edKey = try hosts.importKey(name: "ed", text: String(contentsOfFile: "\(dir)/ck_ed25519"), passphrase: "")
  let rsaKey = try hosts.importKey(name: "rsa", text: String(contentsOfFile: "\(dir)/ck_rsa"), passphrase: "pp123")
  print("ok: imported keys", edKey.kind, rsaKey.kind)
  let gen = hosts.generateEd25519(name: "gen key")
  guard let pub = hosts.publicKey(for: gen) else { print("FAIL no pubkey"); exit(1) }
  try (String(contentsOfFile: "\(dir)/authorized_keys") + pub + "\n").write(toFile: "\(dir)/authorized_keys", atomically: true, encoding: .utf8)
  print("ok: generated", pub.prefix(40))
  var host = SavedHost(label: "local", hostname: "127.0.0.1", port: 2222, username: user, auth: .key, keyID: edKey.id)
  host.forwards = [PortForwardRule(localPort: 28431, remoteHost: "127.0.0.1", remotePort: 28432)]
  hosts.save(host, password: nil)

  let s = mgr.open(host, hosts: hosts, knownHosts: known, prompter: prompter)
  var out = ""
  s.onOutput = { out += String(decoding: Array($0), as: UTF8.self) }
  try await wait("connected (ed25519)") { s.state == .connected }
  s.resize(cols: 100, rows: 30)
  s.send(text: "echo hi-$((1+2)); stty size\r")
  try await wait("shell output") { out.contains("hi-3") && out.contains("30 100") }
  if prompts != 1 { print("FAIL expected 1 host key prompt, got", prompts); exit(1) }

  // SFTP
  let m = SFTPBrowserModel(session: s)
  await m.start()
  print("sftp home:", m.path, "entries:", m.entries.count, m.error ?? "")
  let tmp = URL(fileURLWithPath: "/tmp/dt-up-\(UUID().uuidString.prefix(6)).bin")
  let payload = Data((0..<100_000).map { UInt8($0 % 251) })
  try payload.write(to: tmp)
  await m.upload(tmp)
  if let e = m.error { print("FAIL upload", e); exit(1) }
  guard let entry = m.entries.first(where: { $0.name == tmp.lastPathComponent }) else { print("FAIL uploaded file not listed"); exit(1) }
  print("ok: upload listed size", entry.size ?? 0)
  await m.download(entry)
  guard let dl = m.downloaded, try Data(contentsOf: dl) == payload else { print("FAIL download mismatch", m.error ?? ""); exit(1) }
  print("ok: download matches")
  await m.delete(entry)
  if m.entries.contains(where: { $0.name == entry.name }) { print("FAIL delete"); exit(1) }
  print("ok: delete")

  // Port forward
  try await wait("forward listening") { if case .failed(let m)? = s.forwarders.first?.status { print("forward error:", m) }; return s.forwarders.first?.status == .listening }
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); p.arguments = ["-s", "http://127.0.0.1:28431/hello.txt"]
  let pipe = Pipe(); p.standardOutput = pipe; try p.run()
  let body: String = await Task.detached { p.waitUntilExit(); return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
  print(body.contains("tunnel-ok") ? "ok: port forward" : "FAIL port forward: \(body)")

  mgr.close(s)
  try await wait("closed") { s.state == .closed }

  // RSA key with passphrase, known host now trusted -> no prompt
  var h2 = host; h2.id = UUID(); h2.keyID = rsaKey.id; h2.forwards = []
  hosts.save(h2, password: nil)
  let s2 = mgr.open(h2, hosts: hosts, knownHosts: known, prompter: prompter)
  try await wait("connected (rsa + passphrase, trusted)") { s2.state == .connected }
  if prompts != 1 { print("FAIL unexpected prompt for trusted host"); exit(1) }
  mgr.close(s2)

  // changed key detection
  let e = known.entries[0]
  known.trust(host: e.host, publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
  let s3 = mgr.open(host, hosts: hosts, knownHosts: known, prompter: prompter)
  try await wait("changed-key prompt then connect") { s3.state == .connected }
  if prompts != 2 { print("FAIL changed key did not prompt"); exit(1) }
  mgr.close(s3)
  var h3 = host; h3.id = UUID(); h3.keyID = gen.id; h3.forwards = []
  hosts.save(h3, password: nil)
  let s4 = mgr.open(h3, hosts: hosts, knownHosts: known, prompter: prompter)
  try await wait("connected (in-app generated ed25519)") { s4.state == .connected }
  mgr.close(s4)
  if let pwUser = env["DT_PW_USER"], let pwPass = env["DT_PW_PASS"] {
  let hp = SavedHost(label: "pw", hostname: "127.0.0.1", port: 2223, username: pwUser, auth: .password)
  hosts.save(hp, password: pwPass)
  let s5 = mgr.open(hp, hosts: hosts, knownHosts: known, prompter: prompter)
  var o5 = ""; s5.onOutput = { o5 += String(decoding: Array($0), as: UTF8.self) }
  try await wait("connected (password)") { s5.state == .connected }
  s5.send(text: "whoami\r")
  try await wait("password shell") { o5.contains(pwUser) }
  mgr.close(s5)
  } else { print("skip: password auth (set DT_PW_USER/DT_PW_PASS and run a root sshd on 2223)") }
  print("ALL SMOKE TESTS PASSED")
  exit(0)
}

Task { @MainActor in
  do { try await run() } catch { print("FAIL error:", error); exit(1) }
}
dispatchMain()
