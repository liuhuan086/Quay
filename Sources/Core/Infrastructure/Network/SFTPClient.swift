// SFTPClient.swift
// SFTP implementation using Citadel (pure Swift SSH/SFTP library).
// Swift 6–safe: uses a serial DispatchQueue for state isolation.
import Foundation
import Citadel
import NIOSSH
import NIO
import Crypto

// MARK: - Type alias to avoid name collision
private typealias CitadelSFTP = Citadel.SFTPClient

// MARK: - SFTPClient
public final class SFTPClient: @unchecked Sendable, AnyFTPClient {
    public let config: ServerConfig
    public let supportsResume: Bool = false

    private let queue = DispatchQueue(label: "com.swiftftp.sftp.\(UUID().uuidString)", qos: .userInitiated)

    // Mutable state, only touched on `queue`
    private var sshClient: SSHClient?
    private var sftpHandle: CitadelSFTP?
    private var _isConnected = false

    public var isConnected: Bool {
        get async {
            await withCheckedContinuation { cont in
                queue.async { cont.resume(returning: self._isConnected) }
            }
        }
    }

    public init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Connect
    public func connect(password: String) async throws {
        let authMethod: SSHAuthenticationMethod = .passwordBased(
            username: config.username,
            password: password
        )

        // Enable RSA host keys + DiffieHellman key exchange for broader server compatibility
        var algorithms = SSHAlgorithms()
        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)
        ])
        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha256.self,
            DiffieHellmanGroup14Sha1.self,
        ])

        let ssh = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never,
            algorithms: algorithms
        )

        let sftp = try await ssh.openSFTP()

        queue.async {
            self.sshClient = ssh
            self.sftpHandle = sftp
            self._isConnected = true
        }
    }

    // MARK: - Disconnect
    public func disconnect() async {
        let (ssh, sftp) = await withCheckedContinuation { (cont: CheckedContinuation<(SSHClient?, CitadelSFTP?), Never>) in
            queue.async {
                let result = (self.sshClient, self.sftpHandle)
                self.sshClient = nil
                self.sftpHandle = nil
                self._isConnected = false
                cont.resume(returning: result)
            }
        }
        try? await sftp?.close()
        try? await ssh?.close()
    }

    // MARK: - List Directory
    public func listDirectory(_ path: String) async throws -> [RemoteFileItem] {
        let sftp = try getSFTP()
        // listDirectory returns [SFTPMessage.Name], each has .components: [SFTPPathComponent]
        let nameEntries = try await sftp.listDirectory(atPath: path)
        var results: [RemoteFileItem] = []
        for nameEntry in nameEntries {
            for component in nameEntry.components {
                let name = component.filename
                guard name != "." && name != ".." else { continue }
                let attrs = component.attributes
                let isDir = attrs.permissions.map { ($0 & 0o40000) != 0 } ?? false
                let size = Int64(attrs.size ?? 0)
                let modDate = attrs.accessModificationTime?.modificationTime
                let perms = attrs.permissions.map { formatOctalPermissions($0, isDir: isDir) } ?? ""

                results.append(RemoteFileItem(
                    name: name,
                    path: path.hasSuffix("/") ? path + name : path + "/" + name,
                    isDirectory: isDir,
                    size: size,
                    permissions: perms,
                    modifiedDate: modDate
                ))
            }
        }
        return results
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        let sftp = try getSFTP()
        try await sftp.createDirectory(atPath: path)
    }

    // MARK: - Delete
    public func delete(path: String, isDirectory: Bool) async throws {
        let sftp = try getSFTP()
        if isDirectory {
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    // MARK: - Rename
    public func rename(from: String, to: String) async throws {
        let sftp = try getSFTP()
        try await sftp.rename(at: from, to: to)
    }

    // MARK: - Set Permissions
    public func setPermissions(_ octal: Int, path: String) async throws {
        let sftp = try getSFTP()
        var attrs = SFTPFileAttributes()
        attrs.permissions = UInt32(octal)
        try await sftp.setAttributes(at: path, to: attrs)
    }

    // MARK: - File Size
    public func fileSize(at path: String) async throws -> Int64 {
        let sftp = try getSFTP()
        let attrs = try await sftp.getAttributes(at: path)
        return Int64(attrs.size ?? 0)
    }

    // MARK: - Upload
    public func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let sftp = try getSFTP()
        let fileData = try Data(contentsOf: localURL)
        let total = Int64(fileData.count)

        try await sftp.withFile(filePath: remotePath, flags: [.create, .write, .truncate]) { file in
            let chunkSize = 32_000
            var written: Int64 = 0
            var lastTime = Date()
            var lastBytes: Int64 = 0
            var readOffset = 0

            while readOffset < fileData.count {
                let end = min(readOffset + chunkSize, fileData.count)
                let chunk = fileData[readOffset..<end]
                let buffer = ByteBuffer(data: chunk)
                try await file.write(buffer, at: UInt64(readOffset))
                readOffset = end
                written = Int64(readOffset)

                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                var bps: Int64 = 0
                if elapsed >= 0.3 {
                    bps = Int64(Double(written - lastBytes) / elapsed)
                    lastBytes = written; lastTime = now
                }
                onProgress(TransferProgress(bytesTransferred: written, totalBytes: total, bytesPerSecond: bps))
            }
        }
        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Download
    public func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let sftp = try getSFTP()

        let attrs = try await sftp.getAttributes(at: remotePath)
        let total = Int64(attrs.size ?? 0)

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Read file using withFile for chunked reading
        try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            let allData = try await file.readAll()
            let data = Data(buffer: allData)
            try data.write(to: localURL)
        }

        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Helpers
    private func getSFTP() throws -> CitadelSFTP {
        var result: CitadelSFTP?
        queue.sync { result = self.sftpHandle }
        guard let sftp = result else { throw FTPError.notConnected }
        return sftp
    }

    /// Format POSIX permission bits (UInt32) to rwx string like "drwxr-xr-x"
    private func formatOctalPermissions(_ mode: UInt32, isDir: Bool) -> String {
        var s = isDir ? "d" : "-"
        s += (mode & 0o400 != 0) ? "r" : "-"
        s += (mode & 0o200 != 0) ? "w" : "-"
        s += (mode & 0o100 != 0) ? "x" : "-"
        s += (mode & 0o040 != 0) ? "r" : "-"
        s += (mode & 0o020 != 0) ? "w" : "-"
        s += (mode & 0o010 != 0) ? "x" : "-"
        s += (mode & 0o004 != 0) ? "r" : "-"
        s += (mode & 0o002 != 0) ? "w" : "-"
        s += (mode & 0o001 != 0) ? "x" : "-"
        return s
    }
}

// MARK: - Known-hosts manager (TOFU)
final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()
    private var store: [String: String] = [:]
    private let lock = NSLock()
    private init() { load() }

    func fingerprint(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[host]
    }

    func store(fingerprint: String, for host: String) {
        lock.lock(); defer { lock.unlock() }
        store[host] = fingerprint
        save()
    }

    private var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("SwiftFTP/known_hosts.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        store = dict
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
