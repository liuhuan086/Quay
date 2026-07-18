// SFTPClient.swift
// SFTP implementation using Citadel (pure Swift SSH/SFTP library).
// Swift 6–safe: uses a serial DispatchQueue for state isolation.
import Foundation
@preconcurrency import Citadel
@preconcurrency import NIOSSH
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
    public let supportsResume: Bool = true

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
        guard (1...65_535).contains(config.port) else {
            throw FTPError.connectionFailed("端口必须是 1–65535 之间的整数")
        }
        let authMethod = try makeAuthenticationMethod(password: password)

        // Citadel's broad compatibility preset also enables SHA-1 key exchange
        // and legacy RSA signatures. Keep modern library defaults unless the
        // user explicitly opts into compatibility for an older server.
        let algorithms = config.allowLegacySSHAlgorithms ? SSHAlgorithms.all : SSHAlgorithms()

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
                throw FTPError.connectionFailed(Self.sftpInitializationFailureMessage(
                    host: config.host,
                    port: config.port,
                    detail: detail
                ))
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
                    guard RemoteFileItem.isSafePathComponent(name) else { continue }
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
        } catch let error as CancellationError {
            throw error
        } catch {
            throw FTPError.friendly(error)
        }
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        let sftp = try getSFTP()
        do {
            try await sftp.createDirectory(atPath: path)
        } catch let error as CancellationError {
            throw error
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
            let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let total = (attrs[.size] as? Int64) ?? 0
            guard offset >= 0, offset <= total else {
                throw FTPError.transferFailed("续传偏移量超过本地文件大小")
            }
            if offset > 0 {
                let remoteAttributes = try await sftp.getAttributes(at: remotePath)
                guard Int64(remoteAttributes.size ?? 0) == offset else {
                    throw FTPError.resumeNotSupported
                }
            }

            let flags: SFTPOpenFileFlags = offset > 0 ? [.create, .write] : [.create, .write, .truncate]
            try await sftp.withFile(filePath: remotePath, flags: flags) { file in
                let handle = try FileHandle(forReadingFrom: localURL)
                defer { try? handle.close() }
                if offset > 0 {
                    try handle.seek(toOffset: UInt64(offset))
                }

                let chunkSize = 32_768
                var written = offset
                var lastTime = Date()
                var lastBytes = written
                var bps: Int64 = 0
                var buffer = ByteBufferAllocator().buffer(capacity: chunkSize)

                while true {
                    try Task.checkCancellation()
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    buffer.clear(minimumCapacity: chunkSize)
                    buffer.writeBytes(chunk)
                    try await file.write(buffer, at: UInt64(written))
                    written += Int64(chunk.count)

                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 0.3 {
                        bps = Int64(Double(written - lastBytes) / elapsed)
                        lastBytes = written; lastTime = now
                    }
                    onProgress(TransferProgress(bytesTransferred: written, totalBytes: total, bytesPerSecond: bps))
                }
            }
            let finalAttributes = try await sftp.getAttributes(at: remotePath)
            guard Int64(finalAttributes.size ?? 0) == total else {
                throw FTPError.transferFailed("服务器上的文件大小与上传内容不一致")
            }
            onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
        } catch let error as CancellationError {
            throw error
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
            let stagedURL = TransferFileStaging.downloadURL(for: localURL)
            guard offset >= 0, offset <= total else {
                throw FTPError.transferFailed("续传偏移量超过远端文件大小")
            }

            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let downloadedBytes: Int64 = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                if offset > 0 {
                    guard FileManager.default.fileExists(atPath: stagedURL.path),
                          let localAttributes = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
                          (localAttributes[.size] as? Int64) == offset else {
                        throw FTPError.transferFailed("本地续传文件不存在，请重新开始下载")
                    }
                } else if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try FileManager.default.removeItem(at: stagedURL)
                }
                if !FileManager.default.fileExists(atPath: stagedURL.path) {
                    FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: stagedURL)
                defer { try? handle.close() }
                if offset > 0 {
                    try handle.truncate(atOffset: UInt64(offset))
                    try handle.seek(toOffset: UInt64(offset))
                }

                let chunkSize: UInt32 = 256 * 1024
                var readOffset = UInt64(offset)
                var lastTime = Date()
                var lastBytes = offset
                var bps: Int64 = 0

                while readOffset < UInt64(total) {
                    try Task.checkCancellation()
                    let remaining = UInt64(total) - readOffset
                    let length = UInt32(min(UInt64(chunkSize), remaining))
                    var buffer = try await file.read(from: readOffset, length: length)
                    let readableBytes = buffer.readableBytes
                    guard readableBytes > 0 else {
                        throw FTPError.transferFailed("远端文件在预期大小之前结束")
                    }

                    let data = buffer.readData(length: readableBytes) ?? Data()
                    try handle.write(contentsOf: data)

                    readOffset += UInt64(readableBytes)
                    let transferred = Int64(readOffset)
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 0.3 {
                        bps = Int64(Double(transferred - lastBytes) / elapsed)
                        lastBytes = transferred
                        lastTime = now
                    }
                    onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total, bytesPerSecond: bps))
                }
                return Int64(readOffset)
            }

            guard downloadedBytes == total else {
                throw FTPError.transferFailed("下载字节数不完整（\(downloadedBytes)/\(total)）")
            }
            try Task.checkCancellation()
            try TransferFileStaging.commitDownload(from: stagedURL, to: localURL)
            onProgress(TransferProgress(bytesTransferred: downloadedBytes, totalBytes: total, bytesPerSecond: 0))
        } catch let error as CancellationError {
            throw error
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
        let didStartAccessing = keyURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                keyURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            keyData = try Data(contentsOf: keyURL)
        } catch {
            throw FTPError.sshKeyLoadFailed("无法读取私钥文件：\(keyURL.path)。请在连接设置中通过“选择…”重新授权该私钥。")
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
        if let bookmark = config.sshKeyBookmark {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale else {
                    throw FTPError.sshKeyLoadFailed("私钥文件授权已失效，请在连接设置中重新选择 SSH 私钥")
                }
                if let path = config.sshKeyPath,
                   !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let selectedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
                    guard url.standardizedFileURL.path == selectedPath else {
                        throw FTPError.sshKeyLoadFailed("私钥路径与保存的沙盒授权不一致，请重新选择 SSH 私钥")
                    }
                }
                return url
            } catch let error as FTPError {
                throw error
            } catch {
                throw FTPError.sshKeyLoadFailed("私钥文件授权不可用，请在连接设置中重新选择 SSH 私钥")
            }
        }

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
            hostKeyValidator: .custom(TOFUHostKeyValidator(
                host: "\(config.host):\(config.port)",
                knownHosts: .shared
            )),
            reconnect: .never,
            algorithms: algorithms,
            connectTimeout: .seconds(15)
        )
        let sftp = try await ssh.openSFTP()
        return (ssh, sftp)
    }

    private static func sftpInitializationFailureMessage(host: String, port: Int, detail: String) -> String {
        let lowercased = detail.lowercased()
        if lowercased.contains("singleconnectionfailure")
            || lowercased.contains("connection timed out")
            || lowercased.contains("banner") {
            return "TCP 已连通 \(host):\(port)，但没有收到 SSH/SFTP 协议响应。请确认该端口运行的是 SSH/SFTP 服务，并检查端口转发、防火墙或 sshd 状态。"
        }
        if lowercased.contains("authentication") || lowercased.contains("password") {
            return FTPError.authenticationFailed.errorDescription ?? "用户名或密码错误"
        }
        return "TCP 已连通 \(host):\(port)，但 SSH/SFTP 初始化失败：\(detail)"
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
                        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

private final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let knownHosts: KnownHostsManager

    init(host: String, knownHosts: KnownHostsManager) {
        self.host = host
        self.knownHosts = knownHosts
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let fingerprint = Self.fingerprint(for: hostKey)
            try knownHosts.validate(fingerprint: fingerprint, for: host)
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    private static func fingerprint(for hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        hostKey.write(to: &buffer)
        let data = Data(buffer.readableBytesView)
        let digest = SHA256.hash(data: data)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}

// MARK: - Known-hosts manager (TOFU)
final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()
    private var store: [String: String] = [:]
    private let lock = NSLock()
    private let fileURLOverride: URL?

    init(fileURL: URL? = nil) {
        self.fileURLOverride = fileURL
        load()
    }

    func fingerprint(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[host]
    }

    func validate(fingerprint: String, for host: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let stored = store[host] {
            guard stored == fingerprint else {
                throw FTPError.hostKeyMismatch(host)
            }
            return
        }
        store[host] = fingerprint
        do {
            try saveLocked()
        } catch {
            store.removeValue(forKey: host)
            throw FTPError.connectionFailed("无法安全保存 \(host) 的 SSH 主机指纹：\(error.localizedDescription)")
        }
    }

    private var fileURL: URL {
        if let fileURLOverride {
            return fileURLOverride
        }
        // In a sandboxed build this resolves inside the app container.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("SwiftFTP/known_hosts.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        store = dict
    }

    /// Caller must hold `lock`; keeping serialization and the atomic replace in
    /// the same critical section prevents concurrent first-use connections from
    /// racing the security decision with persistence.
    private func saveLocked() throws {
        let data = try JSONEncoder().encode(store)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
