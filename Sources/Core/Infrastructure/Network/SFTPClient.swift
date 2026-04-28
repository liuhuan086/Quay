// SFTPClient.swift
// SFTP implementation using Citadel (pure Swift SSH/SFTP library).
// Swift 6–safe: uses a serial DispatchQueue for state isolation.
import Foundation
import Citadel
import NIOSSH
import NIO
import Crypto
import Darwin
import Network

// MARK: - Type alias to avoid name collision
private typealias CitadelSFTP = Citadel.SFTPClient

private final class TCPProbeContinuation: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

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
        let authMethod = try makeAuthenticationMethod(password: password)

        // Enable RSA host keys + DiffieHellman key exchange for broader server compatibility
        var algorithms = SSHAlgorithms()
        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)
        ])
        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha256.self,
            DiffieHellmanGroup14Sha1.self,
        ])

        do {
            let (ssh, sftp) = try await connectSFTP(
                host: config.host,
                authenticationMethod: authMethod,
                algorithms: algorithms
            )
            storeConnection(ssh: ssh, sftp: sftp)
        } catch {
            guard FTPError.isHostReachabilityFailure(error) else {
                throw FTPError.friendly(error)
            }

            if await isTCPReachable(host: config.host, port: config.port) {
                let detail = String(describing: error)
                throw FTPError.connectionFailed("TCP 已连通 \(config.host):\(config.port)，但 SSH/SFTP 初始化失败。底层错误：\(detail)")
            }

            var lastError: Error = error
            let fallbackHosts = await Self.ipv4Addresses(for: config.host)
            for host in fallbackHosts {
                do {
                    let (ssh, sftp) = try await connectSFTP(
                        host: host,
                        authenticationMethod: authMethod,
                        algorithms: algorithms
                    )
                    storeConnection(ssh: ssh, sftp: sftp)
                    return
                } catch {
                    lastError = error
                    if !FTPError.isHostReachabilityFailure(error) {
                        break
                    }
                }
            }

            throw FTPError.friendly(lastError)
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
        do {
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
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        let sftp = try getSFTP()
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Delete
    public func delete(path: String, isDirectory: Bool) async throws {
        let sftp = try getSFTP()
        do {
            if isDirectory {
                try await sftp.rmdir(at: path)
            } else {
                try await sftp.remove(at: path)
            }
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Rename
    public func rename(from: String, to: String) async throws {
        let sftp = try getSFTP()
        do {
            try await sftp.rename(at: from, to: to)
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Set Permissions
    public func setPermissions(_ octal: Int, path: String) async throws {
        let sftp = try getSFTP()
        do {
            var attrs = SFTPFileAttributes()
            attrs.permissions = UInt32(octal)
            try await sftp.setAttributes(at: path, to: attrs)
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - File Size
    public func fileSize(at path: String) async throws -> Int64 {
        let sftp = try getSFTP()
        do {
            let attrs = try await sftp.getAttributes(at: path)
            return Int64(attrs.size ?? 0)
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Upload
    public func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let sftp = try getSFTP()
        do {
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
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Download
    public func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let sftp = try getSFTP()
        do {
            let attrs = try await sftp.getAttributes(at: remotePath)
            let total = Int64(attrs.size ?? 0)

            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                FileManager.default.createFile(atPath: localURL.path, contents: nil)

                let handle = try FileHandle(forWritingTo: localURL)
                defer { try? handle.close() }

                let chunkSize: UInt32 = 256 * 1024
                var readOffset: UInt64 = 0
                var lastTime = Date()
                var lastBytes: Int64 = 0

                while readOffset < UInt64(total) {
                    let remaining = UInt64(total) - readOffset
                    let length = UInt32(min(UInt64(chunkSize), remaining))
                    var buffer = try await file.read(from: readOffset, length: length)
                    let readableBytes = buffer.readableBytes
                    guard readableBytes > 0 else { break }

                    let data = buffer.readData(length: readableBytes) ?? Data()
                    try handle.write(contentsOf: data)

                    readOffset += UInt64(readableBytes)
                    let transferred = Int64(readOffset)
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTime)
                    var bps: Int64 = 0
                    if elapsed >= 0.3 {
                        bps = Int64(Double(transferred - lastBytes) / elapsed)
                        lastBytes = transferred
                        lastTime = now
                    }
                    onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total, bytesPerSecond: bps))
                }
            }

            onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Helpers
    private func makeAuthenticationMethod(password: String) throws -> SSHAuthenticationMethod {
        guard config.useSSHKey else {
            return .passwordBased(username: config.username, password: password)
        }

        let keyURL = try privateKeyURL()
        let keyData: Data
        do {
            keyData = try Data(contentsOf: keyURL)
        } catch {
            throw FTPError.sshKeyLoadFailed("无法读取私钥文件：\(keyURL.path)")
        }

        let passphrase = password.isEmpty ? nil : Data(password.utf8)

        do {
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: passphrase)
            return .ed25519(username: config.username, privateKey: privateKey)
        } catch {
            do {
                let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyData, decryptionKey: passphrase)
                return .rsa(username: config.username, privateKey: privateKey)
            } catch {
                throw FTPError.sshKeyLoadFailed("私钥格式不支持或密钥密码不正确：\(keyURL.path)")
            }
        }
    }

    private func privateKeyURL() throws -> URL {
        let candidates: [String]
        if let path = config.sshKeyPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates = [path]
        } else {
            candidates = ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"]
        }

        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        throw FTPError.sshKeyLoadFailed("找不到私钥文件，请在连接设置中选择 SSH 私钥")
    }

    private func connectSFTP(
        host: String,
        authenticationMethod: SSHAuthenticationMethod,
        algorithms: SSHAlgorithms
    ) async throws -> (SSHClient, CitadelSFTP) {
        let ssh = try await SSHClient.connect(
            host: host,
            port: config.port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never,
            algorithms: algorithms,
            connectTimeout: .seconds(15)
        )
        let sftp = try await ssh.openSFTP()
        return (ssh, sftp)
    }

    private func isTCPReachable(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let box = TCPProbeContinuation(continuation)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.cancel()
                    box.resume(returning: true)
                case .failed:
                    conn.cancel()
                    box.resume(returning: false)
                case .cancelled:
                    box.resume(returning: false)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                conn.cancel()
                box.resume(returning: false)
            }
        }
    }

    private func storeConnection(ssh: SSHClient, sftp: CitadelSFTP) {
        queue.async {
            self.sshClient = ssh
            self.sftpHandle = sftp
            self._isConnected = true
        }
    }

    private static func ipv4Addresses(for host: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
                return []
            }
            defer { freeaddrinfo(result) }

            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = result
            while let current = cursor {
                if current.pointee.ai_family == AF_INET,
                   let sockaddr = current.pointee.ai_addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let sin = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var address = sin.sin_addr
                    if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let value = String(cString: buffer)
                        if !addresses.contains(value) {
                            addresses.append(value)
                        }
                    }
                }
                cursor = current.pointee.ai_next
            }
            return addresses
        }.value
    }

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
