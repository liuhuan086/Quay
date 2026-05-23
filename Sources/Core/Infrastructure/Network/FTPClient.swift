// FTPClient.swift
// Swift 6–compatible FTP/FTPS implementation.
// Uses a non-isolated class with an internal serial DispatchQueue for state safety
// instead of `actor`, which avoids the "conformance crosses actor-isolated code" error.
import Foundation
import Network
import Security

// MARK: - Internal state box (isolated by queue)
private final class FTPState: @unchecked Sendable {
    var controlConn: NWConnection?
    var isConnected: Bool = false
    var receiveBuffer = Data()
}

// MARK: - FTPClient
public final class FTPClient: AnyFTPClient {
    // MARK: Properties
    public let config: ServerConfig
    public let supportsResume: Bool = true

    // Internal queue owns all mutable state
    private let queue = DispatchQueue(label: "com.swiftftp.ftpclient", qos: .userInitiated)
    private let state = FTPState()

    // MARK: Init
    public init(config: ServerConfig) {
        self.config = config
    }

    // MARK: isConnected (async computed, safe to call from any context)
    public var isConnected: Bool {
        get async { await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.state.isConnected) }
        }}
    }

    // MARK: - Connect
    public func connect(password: String) async throws {
        let params: NWParameters
        if config.protocol_ == .ftps {
            let tls = NWProtocolTLS.Options()
            if config.allowSelfSignedTLS {
                let host = config.host
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, trust, complete in
                        complete(Self.shouldAllowFTPSCertificateOverride(trust: trust, host: host))
                    },
                    queue
                )
            }
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
        // 给 TCP 设一个较短的连接超时，否则失败时 NWConnection 会一直挂着不抛错
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 15
        }

        let conn = NWConnection(
            host: .init(config.host),
            port: .init(integerLiteral: UInt16(config.port)),
            using: params
        )

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let box = ContinuationBox(cont)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:            box.resume()
                    case .failed(let err):  box.resume(throwing: FTPError.friendly(err))
                    case .waiting:          break
                    case .cancelled:        box.resume(throwing: FTPError.connectionFailed("连接已被取消"))
                    default: break
                    }
                }
                conn.start(queue: queue)
                self.queue.async { self.state.controlConn = conn }
            }
        } catch {
            conn.cancel()
            throw FTPError.friendly(error)
        }

        do {
            let welcome = try await readControlLine()
            guard welcome.hasPrefix("220") else { throw FTPError.badResponse(welcome) }

            try await sendCtrl("USER \(config.username)")
            let userResp = try await readControlLine()

            if userResp.hasPrefix("331") {
                try await sendCtrl("PASS \(password)")
                let passResp = try await readControlLine()
                guard passResp.hasPrefix("230") else { throw FTPError.authenticationFailed }
            } else if !userResp.hasPrefix("230") {
                throw FTPError.authenticationFailed
            }

            try await sendCtrl("TYPE I");   _ = try await readControlLine()
            try await sendCtrl("OPTS UTF8 ON"); _ = try? await readControlLine()
        } catch {
            // 登录阶段任何失败都应清理底层 socket，避免遗留半开连接
            conn.cancel()
            queue.async {
                self.state.controlConn = nil
                self.state.isConnected = false
                self.state.receiveBuffer.removeAll()
            }
            throw FTPError.friendly(error)
        }

        queue.async { self.state.isConnected = true }
    }

    // MARK: - Disconnect
    public func disconnect() async {
        try? await sendCtrl("QUIT")
        queue.async {
            self.state.controlConn?.cancel()
            self.state.controlConn = nil
            self.state.isConnected = false
            self.state.receiveBuffer.removeAll()
        }
    }

    // MARK: - List Directory
    public func listDirectory(_ path: String) async throws -> [RemoteFileItem] {
        guard await isConnected else { throw FTPError.notConnected }
        let data = try await transferData { dataConn in
            // Try MLSD first
            try await self.sendCtrl("MLSD \(path)")
            let r = try await self.readControlLine()
            guard r.hasPrefix("150") || r.hasPrefix("125") else {
                throw FTPError.badResponse(r)
            }
            return try await self.receiveAll(on: dataConn)
        }
        let listing = String(data: data, encoding: .utf8) ?? ""
        let mlsd = Self.parseMLSD(listing, base: path)
        return mlsd.isEmpty
             ? try await listFallback(path)   // fallback to LIST
             : mlsd
    }

    private func listFallback(_ path: String) async throws -> [RemoteFileItem] {
        let data = try await transferData { dataConn in
            try await self.sendCtrl("LIST \(path)")
            let r = try await self.readControlLine()
            guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.badResponse(r) }
            return try await self.receiveAll(on: dataConn)
        }
        let listing = String(data: data, encoding: .utf8) ?? ""
        return Self.parseLIST(listing, base: path)
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        try await sendCtrl("MKD \(path)")
        let r = try await readControlLine()
        guard r.hasPrefix("257") else { throw FTPError.badResponse(r) }
    }

    // MARK: - Delete
    public func delete(path: String, isDirectory: Bool) async throws {
        let cmd = isDirectory ? "RMD \(path)" : "DELE \(path)"
        try await sendCtrl(cmd)
        let r = try await readControlLine()
        guard r.hasPrefix("250") else { throw FTPError.permissionDenied(path) }
    }

    // MARK: - Rename
    public func rename(from: String, to: String) async throws {
        try await sendCtrl("RNFR \(from)")
        let r1 = try await readControlLine()
        guard r1.hasPrefix("350") else { throw FTPError.badResponse(r1) }
        try await sendCtrl("RNTO \(to)")
        let r2 = try await readControlLine()
        guard r2.hasPrefix("250") else { throw FTPError.badResponse(r2) }
    }

    // MARK: - Set Permissions
    public func setPermissions(_ octal: Int, path: String) async throws {
        try await sendCtrl("SITE CHMOD \(String(octal, radix: 8)) \(path)")
        _ = try await readControlLine()
    }

    // MARK: - File Size
    public func fileSize(at path: String) async throws -> Int64 {
        try await sendCtrl("SIZE \(path)")
        let r = try await readControlLine()
        guard r.hasPrefix("213"),
              let size = Int64(r.dropFirst(4).trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return size
    }

    // MARK: - Upload (with REST resume)
    public func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        guard await isConnected else { throw FTPError.notConnected }

        let attrs  = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total  = (attrs[.size] as? Int64) ?? 0

        // Send REST to set resume offset
        if offset > 0 {
            try await sendCtrl("REST \(offset)")
            let r = try await readControlLine()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        defer { dataConn.cancel() }
        try await sendCtrl("STOR \(remotePath)")
        let r = try await readControlLine()
        guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.badResponse(r) }

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

        var sent: Int64 = offset
        let chunkSize = 131_072   // 128 KB
        var lastTime = Date()
        var lastBytes = sent
        var bps: Int64 = 0

        while true {
            try Task.checkCancellation()
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            try await send(data: chunk, on: dataConn)
            sent += Int64(chunk.count)

            let now = Date()
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.3 {
                bps = Int64(Double(sent - lastBytes) / elapsed)
                lastBytes = sent; lastTime = now
            }
            onProgress(TransferProgress(bytesTransferred: sent, totalBytes: total, bytesPerSecond: bps))
        }

        _ = try await readControlLine()   // 226
        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Download (with REST resume)
    public func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        guard await isConnected else { throw FTPError.notConnected }
        let total = try await fileSize(at: remotePath)

        if offset > 0 {
            try await sendCtrl("REST \(offset)")
            let r = try await readControlLine()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        defer { dataConn.cancel() }
        try await sendCtrl("RETR \(remotePath)")
        let r = try await readControlLine()
        guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.fileNotFound(remotePath) }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let handle: FileHandle
        if offset > 0, FileManager.default.fileExists(atPath: localURL.path) {
            handle = try FileHandle(forWritingTo: localURL)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: localURL)
        }
        defer { try? handle.close() }

        var received: Int64 = offset
        var lastTime = Date(); var lastBytes = received
        var bps: Int64 = 0

        try await stream(on: dataConn) { chunk in
            handle.write(chunk)
            received += Int64(chunk.count)
            let now = Date(); let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.3 { bps = Int64(Double(received - lastBytes) / elapsed); lastBytes = received; lastTime = now }
            onProgress(TransferProgress(bytesTransferred: received, totalBytes: total, bytesPerSecond: bps))
        }

        _ = try await readControlLine()
        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Private: PASV
    private func openPASV() async throws -> NWConnection {
        try await sendCtrl("PASV")
        let r = try await readControlLine()
        guard r.hasPrefix("227") else { throw FTPError.badResponse(r) }
        let (host, port) = try Self.parsePASV(r)
        let params: NWParameters = .tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 15
        }
        let conn = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(port)), using: params)
        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:           box.resume(returning: conn)
                case .failed(let e):
                    let mapped = FTPError.friendly(e)
                    box.resume(throwing: FTPError.dataConnectionFailed(mapped.errorDescription ?? "未知错误"))
                case .waiting:
                    break
                case .cancelled:
                    box.resume(throwing: FTPError.dataConnectionFailed("连接已被取消"))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Helper to run a data-channel transfer and always read the trailing "226".
    /// The block must read everything it needs from the data connection and return it.
    private func transferData(_ block: (NWConnection) async throws -> Data) async throws -> Data {
        let dataConn = try await openPASV()
        let captured: Data
        do {
            captured = try await block(dataConn)
        } catch {
            dataConn.cancel()
            throw error
        }
        // Read 226 Transfer complete (best-effort)
        _ = try? await readControlLine()
        dataConn.cancel()
        return captured
    }

    static func parsePASV(_ msg: String) throws -> (String, Int) {
        guard let s = msg.firstIndex(of: "("), let e = msg.firstIndex(of: ")") else {
            throw FTPError.badResponse("Invalid PASV: \(msg)")
        }
        let parts = String(msg[msg.index(after: s)..<e]).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 6 else { throw FTPError.badResponse("Bad PASV: \(msg)") }
        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4]*256 + parts[5])
    }

    // MARK: - Private: Send / Receive
    private func sendCtrl(_ cmd: String) async throws {
        guard let conn = await withCheckedContinuation({ (cont: CheckedContinuation<NWConnection?, Never>) in
            queue.async { cont.resume(returning: self.state.controlConn) }
        }) else { throw FTPError.notConnected }

        let data = (cmd + "\r\n").data(using: .utf8)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func send(data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    let friendly = FTPError.friendly(err)
                    cont.resume(throwing: FTPError.transferFailed(friendly.errorDescription ?? "未知错误"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readControlLine() async throws -> String {
        while true {
            let buf = await withCheckedContinuation({ (cont: CheckedContinuation<Data, Never>) in
                queue.async { cont.resume(returning: self.state.receiveBuffer) }
            })
            if let range = buf.range(of: Data("\r\n".utf8)) {
                let line = buf.subdata(in: buf.startIndex..<range.lowerBound)
                queue.async { self.state.receiveBuffer.removeSubrange(self.state.receiveBuffer.startIndex..<range.upperBound) }
                return String(data: line, encoding: .utf8) ?? ""
            }
            guard let conn = await withCheckedContinuation({ (cont: CheckedContinuation<NWConnection?, Never>) in
                queue.async { cont.resume(returning: self.state.controlConn) }
            }) else { throw FTPError.notConnected }

            let chunk = try await recv(from: conn, min: 1, max: 4096)
            queue.async { self.state.receiveBuffer.append(chunk) }
        }
    }

    private func recv(from conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, _, err in
                if let err { cont.resume(throwing: FTPError.friendly(err)) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func receiveAll(on conn: NWConnection) async throws -> Data {
        var all = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            all.append(chunk)
        }
        return all
    }

    private func stream(on conn: NWConnection, handler: (Data) throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            try handler(chunk)
        }
    }

    // MARK: - Parsers
    static func parseMLSD(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFileItem? in
            let s = String(line)
            guard let spaceIdx = s.firstIndex(of: " ") else { return nil }
            let facts = String(s[s.startIndex..<spaceIdx])
            let name = String(s[s.index(after: spaceIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name != "." && name != ".." else { return nil }

            var isDir = false; var size: Int64 = 0; var date: Date? = nil
            for fact in facts.split(separator: ";") {
                let kv = fact.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "type":   isDir = kv[1].lowercased().contains("dir")
                case "size":   size  = Int64(kv[1]) ?? 0
                case "modify":
                    let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
                    date = f.date(from: String(kv[1]))
                default: break
                }
            }
            return RemoteFileItem(name: name, path: joinedRemotePath(base: base, name: name),
                                  isDirectory: isDir, size: size, modifiedDate: date)
        }
    }

    static func parseLIST(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFileItem? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { return nil }
            let perm = String(parts[0]); let isDir = perm.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0
            let name = parts[8...]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name != "." && name != ".." else { return nil }
            return RemoteFileItem(name: name, path: joinedRemotePath(base: base, name: name),
                                  isDirectory: isDir, size: size, permissions: perm)
        }
    }

    private static func joinedRemotePath(base: String, name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: - FTPS trust exceptions
    static func shouldAllowFTPSCertificateOverride(errorCodes: Set<Int>, description: String) -> Bool {
        let lowercased = description.lowercased()
        let deniedCodes: Set<Int> = [
            Int(errSecHostNameMismatch),
            Int(errSSLHostNameMismatch),
            Int(errSecCertificateRevoked)
        ]
        let allowedCodes: Set<Int> = [
            Int(errSecCertificateExpired),
            Int(errSecCertificateNotValidYet),
            Int(errSecNotTrusted),
            Int(errSecInvalidCertAuthority)
        ]

        if !errorCodes.isDisjoint(with: deniedCodes) {
            return false
        }
        if lowercased.contains("host name")
            || lowercased.contains("hostname")
            || lowercased.contains("name mismatch")
            || lowercased.contains("revoked")
            || lowercased.contains("revocation") {
            return false
        }
        return !errorCodes.isDisjoint(with: allowedCodes)
    }

    private static func shouldAllowFTPSCertificateOverride(trust: sec_trust_t, host: String) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))

        var error: CFError?
        if SecTrustEvaluateWithError(secTrust, &error) {
            return true
        }
        guard let error else { return false }
        return shouldAllowFTPSCertificateOverride(
            errorCodes: trustErrorCodes(from: error),
            description: CFErrorCopyDescription(error) as String
        )
    }

    private static func trustErrorCodes(from error: CFError) -> Set<Int> {
        var codes = Set([Int(CFErrorGetCode(error))])
        let nsError = error as Error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes.insert(underlying.code)
        }
        if let underlying = nsError.userInfo[kCFErrorUnderlyingErrorKey as String] as? NSError {
            codes.insert(underlying.code)
        }
        return codes
    }
}

// MARK: - ContinuationBox (one-shot resume guard)
/// Wraps a CheckedContinuation so it can only be resumed once,
/// even if NWConnection fires stateUpdateHandler multiple times.
final class ContinuationBox<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func resume(returning value: sending T) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(returning: value); cont = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(throwing: error); cont = nil
    }
}

// Overload for Void continuations
extension ContinuationBox where T == Void {
    func resume() { resume(returning: ()) }
}
