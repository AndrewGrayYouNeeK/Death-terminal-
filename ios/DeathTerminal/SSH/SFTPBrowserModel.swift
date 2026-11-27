import Foundation
import Combine
import Citadel
import NIOCore

struct SFTPEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: UInt64?
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published var path = ""
    @Published var entries: [SFTPEntry] = []
    @Published var loading = false
    @Published var error: String?
    @Published var status: String?
    @Published var downloaded: URL?

    let session: SSHSession
    init(session: SSHSession) { self.session = session }

    func start() async {
        do {
            let sftp = try await session.sftpClient()
            let home = try await sftp.getRealPath(atPath: ".")
            await list(home)
        } catch { show(error) }
    }

    func list(_ dir: String) async {
        loading = true
        defer { loading = false }
        do {
            let sftp = try await session.sftpClient()
            let names = try await sftp.listDirectory(atPath: dir)
            entries = names.flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { c in
                    let perms = c.attributes.permissions ?? 0
                    let isDir = (perms & 0o170000) == 0o040000 || c.longname.hasPrefix("d")
                    return SFTPEntry(name: c.filename, isDirectory: isDir, size: c.attributes.size)
                }
                .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
            path = dir
            error = nil
        } catch { show(error) }
    }

    func child(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }

    var parent: String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    func download(_ entry: SFTPEntry) async {
        status = "Downloading \(entry.name)…"
        defer { status = nil }
        do {
            let sftp = try await session.sftpClient()
            let buffer = try await sftp.withFile(filePath: child(entry.name), flags: .read) { file in
                try await file.readAll()
            }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(entry.name)
            try Data(buffer.readableBytesView).write(to: url, options: .atomic)
            downloaded = url
        } catch { show(error) }
    }

    func upload(_ local: URL) async {
        let scoped = local.startAccessingSecurityScopedResource()
        defer { if scoped { local.stopAccessingSecurityScopedResource() } }
        status = "Uploading \(local.lastPathComponent)…"
        defer { status = nil }
        do {
            let data = try Data(contentsOf: local)
            let sftp = try await session.sftpClient()
            let target = child(local.lastPathComponent)
            try await sftp.withFile(filePath: target, flags: [.write, .create, .truncate]) { file in
                let chunk = 32 * 1024
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunk, data.count)
                    try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                    offset = end
                }
            }
            await list(path)
        } catch { show(error) }
    }

    func delete(_ entry: SFTPEntry) async {
        do {
            let sftp = try await session.sftpClient()
            if entry.isDirectory { try await sftp.rmdir(at: child(entry.name)) }
            else { try await sftp.remove(at: child(entry.name)) }
            await list(path)
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

